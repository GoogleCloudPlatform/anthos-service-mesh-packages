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
      # Read from the named pipe into the cloudkey variable
      cloudkey="$(cat "${file}")"
      # Clean up
      rm "${file}"
    fi
  fi

  echo ${cloudkey}
}

# Runtime Checks
if [[ "" == "$(which gcloud)" ]]; then
  fatal "No gcloud found, exiting."
fi

# Environment Variables
PROJECT_ID="${PROJECT_ID?Environment variable PROJECT_ID is required}"
CLUSTER_NAME="${CLUSTER_NAME:-asm-free-trial}"
CLUSTER_ZONE="${CLUSTER_ZONE:-us-central1-c}"
ZONE="$(getZone "${CLUSTER_ZONE}")"
NETWORK_NAME=$(basename "$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" --zone="${ZONE}" \
    --format='value(networkConfig.network)')")
SUBNETWORK_NAME=$(basename "$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" \
    --zone="${ZONE}" --format='value(networkConfig.subnetwork)')")

# Getting network tags is painful. Get the instance groups, map to an instance,
# and get the node tag from it (they should be the same across all nodes -- we don't
# know how to handle it, otherwise).
INSTANCE_GROUP=$(gcloud container clusters describe "${CLUSTER_NAME}" --project "${PROJECT_ID}" --zone="${ZONE}" --format='flattened(nodePools[].instanceGroupUrls[].scope().segment())' |  cut -d ':' -f2 | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/::space:]]*$//')
INSTANCE_GROUP_ZONE=$(gcloud compute instance-groups list --filter="name=(${INSTANCE_GROUP})" --format="value(zone)" | sed 's|^.*/||g')
sleep 1
INSTANCE=$(gcloud compute instance-groups list-instances "${INSTANCE_GROUP}" --project "${PROJECT_ID}" \
    --zone="${INSTANCE_GROUP_ZONE}" --format="value(instance)" --limit 1)
NETWORK_TAGS=$(gcloud compute instances describe "${INSTANCE}" --zone="${INSTANCE_GROUP_ZONE}" --project "${PROJECT_ID}" --format="value(tags.items)")

NEGZONE=""
if isRegion "${CLUSTER_ZONE}"; then
  NEGZONE="region = ${CLUSTER_ZONE}"
else
  NEGZONE="local-zone = ${CLUSTER_ZONE}"
fi

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
EOF
)

export KUBECONFIG="${TMPDIR}/${CLUSTER_NAME}/kube.yaml"
gcloud container clusters get-credentials "${CLUSTER_NAME}" --zone "${ZONE}"

# Update the cluster with the GCP-specific configmaps
kubectl -n kube-system apply -f <(echo "${CONFIGMAP_NEG}")
if ! kubectl -n kube-system get secret google-cloud-key > /dev/null 2>&1; then
  kubectl -n kube-system create secret generic google-cloud-key  --from-file key.json=<(fetchCloudKey neg-service-account)
  kubectl -n kube-system delete pod -lk8s-app=gcp-lb-controller
  kubectl -n kube-system annotate cm ingress-gce-lock control-plane.alpha.kubernetes.io/leader-
  kubectl -n kube-system delete pod -lk8s-app=gcp-lb-controller --wait=false
fi

if ! kubectl get ns istio-system > /dev/null; then
  kubectl create ns istio-system
fi
if ! kubectl -n istio-system get secret google-cloud-key > /dev/null 2>&1; then
  kubectl -n istio-system create secret generic google-cloud-key  --from-file key.json=<(fetchCloudKey asm-galley)
fi

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member serviceAccount:service-$(gcloud projects list --filter="project_id=${PROJECT_ID}" --format='value(project_number)')@gcp-sa-meshdataplane.iam.gserviceaccount.com \
    --role roles/compute.networkViewer

