#!/bin/bash
set -euo pipefail

# Helper functions and run environment setup
TMPDIR="$(mktemp -d -t tmp.XXXXX)"
function cleanup {
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

function isRegion {
  if [[ -z "$(gcloud compute regions list --filter="name=('${1:-}')" --format="csv[no-heading](name)")" ]]; then
    false
  else
    true
  fi
}

function isZone {
  if [[ -z "$(gcloud compute zones list --filter="name=('${1:-}')" --format="csv[no-heading](name)")" ]]; then
    false
  else
    true
  fi
}

function getZone {
  if isRegion "${1}"; then
    echo "${1}-a"
  fi
  if isZone "${1}"; then
    echo "${1}"
  fi
}

function fatal {
  echo "$1"
  exit 1
}

function fetchCloudKey {
  # The gcloud key create command requires you dump its service account
  # credentials to a file. Let that happen, then pull the contents into a varaible
  # and delete the file.
  cloudkey=""
  serviceaccount=${1?Must pass serviceaccount as argument to function fetchCloudKey}
  if [[ "${CLUSTER_NAME}" != "" ]]; then
    if ! kubectl -n kube-system get secret google-cloud-key >/dev/null 2>&1 || ! kubectl -n istio-system get secret google-cloud-key > /dev/null 2>&1; then
      file="${TMPDIR}/${CLUSTER_NAME}/${CLUSTER_NAME}-${serviceaccount}-cloudkey.json"
      gcloud iam service-accounts keys create "${file}" --iam-account="${serviceaccount}"@"${PROJECT_ID}".iam.gserviceaccount.com
      if [[ ! -f "${file}" ]]; then
        fatal "Error creating SA key '${file}' for account ${serviceaccount}@${PROJECT_ID}.iam.gserviceaccount.com -- exiting."
      fi
      # Read from the named pipe into the cloudkey variable
      cloudkey="$(cat "${file}")"
      # Clean up
      rm "${file}"
    fi
  fi

  echo ${cloudkey}
}

function getLocationFlag {
  location=$1
  if (isRegion $location); then
      echo "--region=${LOCATION}"
  else
      echo "--zone=${ZONE}"
  fi
}

# Runtime Checks
if [[ "" == "$(which gcloud)" ]]; then
  fatal "No gcloud found, exiting."
fi

# Environment Variables
PROJECT_ID="${PROJECT_ID?Environment variable PROJECT_ID is required}"
CLUSTER_NAME="${CLUSTER_NAME:-asm-free-trial}"
LOCATION="${LOCATION:-us-central1-c}"
ZONE="$(getZone "${LOCATION}")"
NETWORK_NAME=$(basename "$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" $(getLocationFlag "${LOCATION}") \
    --format='value(networkConfig.network)')")
SUBNETWORK_NAME=$(basename "$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" \
    $(getLocationFlag "${LOCATION}") --format='value(networkConfig.subnetwork)')")

# Getting network tags is painful. Get the instance groups, map to an instance,
# and get the node tag from it (they should be the same across all nodes -- we don't
# know how to handle it, otherwise).
INSTANCE_GROUP=$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" $(getLocationFlag "${LOCATION}") --format='flattened(nodePools[].instanceGroupUrls[].scope().segment())' |  cut -d ':' -f2 | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/::space:]]*$//')
INSTANCE_GROUP_ZONE=$(gcloud compute instance-groups list --filter="name=(${INSTANCE_GROUP})" --format="value(zone)" | sed 's|^.*/||g')
sleep 1
INSTANCE=$(gcloud compute instance-groups list-instances "${INSTANCE_GROUP}" --project "${PROJECT_ID}" \
    --zone="${INSTANCE_GROUP_ZONE}" --format="value(instance)" --limit 1)
NETWORK_TAGS=$(gcloud compute instances describe "${INSTANCE}" --zone="${INSTANCE_GROUP_ZONE}" --project "${PROJECT_ID}" --format="value(tags.items)")

NEGZONE=""
if isRegion "${LOCATION}"; then
  NEGZONE="region = ${LOCATION}"
else
  NEGZONE="local-zone = ${LOCATION}"
fi

COMPUTE_API_ENDPOINT="${COMPUTE_API_ENDPOINT:-}"
CONTAINER_API_ENDPOINT="${CONTAINER_API_ENDPOINT:-}"

CONFIGMAP_NEG=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gce-config
  namespace: kube-system
data:
  gce.conf: |
    [global]
    token-url = nil
    # Your cluster's project
    project-id = ${PROJECT_ID}
    # Your cluster's network
    network-name =  ${NETWORK_NAME}
    # Your cluster's subnetwork
    subnetwork-name = ${SUBNETWORK_NAME}
    # Prefix for your cluster's IG
    node-instance-prefix = gke-${CLUSTER_NAME}
    # Network tags for your cluster's IG
    node-tags = ${NETWORK_TAGS}
    # Zone the cluster lives in
    ${NEGZONE}
    # GCE compute API endpoint to use. If this is blank, then the default endpoint is used.
    api-endpoint = "${COMPUTE_API_ENDPOINT}"
    # GCE container API endpoint to use. If this is blank, then the default endpoint is used.
    container-api-endpoint = "${CONTAINER_API_ENDPOINT}"
EOF
)

export KUBECONFIG="${TMPDIR}/${CLUSTER_NAME}/kube.yaml"
gcloud container clusters get-credentials "${CLUSTER_NAME}" $(getLocationFlag "${LOCATION}")

# Update the cluster with the GCP-specific configmaps
kubectl -n kube-system apply -f <(echo "${CONFIGMAP_NEG}")
if ! kubectl -n kube-system get secret google-cloud-key > /dev/null 2>&1; then
  kubectl -n kube-system create secret generic google-cloud-key  --from-file key.json=<(fetchCloudKey neg-service-account)
  kubectl -n kube-system delete pod -lk8s-app=gcp-lb-controller --wait=false
fi
