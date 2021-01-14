#!/bin/bash
set -CeEu
set -o pipefail

BUILD_ID="${BUILD_ID:=}"; export BUILD_ID;
PROJECT_ID="${PROJECT_ID:=}"; export PROJECT_ID;
CLUSTER_LOCATION="${CLUSTER_LOCATION:=us-central1-c}"; export CLUSTER_LOCATION;
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:=}"; export SERVICE_ACCOUNT;
KEY_FILE="${KEY_FILE:=}"; export KEY_FILE;
OSS_VERSION="${OSS_VERSION:=1.8.1}"; export OSS_VERSION;
OLD_OSS_VERSION="${OLD_OSS_VERSION:=1.7.1}"; export OLD_OSS_VERSION;

KUBECONFIG=""

IS_LOCAL=1
SDIR="${SDIR:=.}"

if [[ -n "${KEY_FILE}" ]]; then
  KEY_FILE="$(readlink -f "$KEY_FILE")"
fi

### script convenience functions
warn() {
  echo "$1" >&2
}

fatal() {
  warn "$1"
  exit 2
}

fatal_with_usage() {
  warn "$1"
  usage
  exit 2
}

arg_required() {
  if [[ ! "$2" || "${2:0:1}" = '-' ]]; then
    fatal "ERROR: Option $1 requires an argument."
  fi
}

check_exists() {
  if [[ -z "${!1}" ]]; then
    fatal "ERROR: $1 is missing but required." >&2
  fi
}

fail() {
  echo "FAILED: $1" >&2
}

success() {
  echo "SUCCESS: $1" >&2
}
#
### interface functions, common for all tests
usage() {
  cat << EOF
usage: $0 [OPTION]...

All options can also be passed via environment variables by using the ALL_CAPS
name. Options specified via flags take precedence over environment variables.

OPTIONS:
  -p|--project_id        <ID>         The GCP project ID
  -l|--cluster_location  <LOCATION>   (optional) The GCP zone to create any
                                      necessary resources. Defaults to
                                      us-central1-c.
  -s|--service_account   <ACCOUNT>    (optional) The name of a service account
                                      used to install ASM
  -k|--key_file          <FILE PATH>  (optional) The key file for a service
                                      account. Required if --service_account is
                                      passed.
  -b|--build_id          <STRING>     (optional) A CI/CD build id, used to
                                      prevent name collisions and associate
                                      resources with runs. Defaults to 10 chars
                                      from /dev/urandom, for running locally.

  -h|--help                           Show this message and exit.
EOF
}

parse_args() {
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  while [[ $# != 0 ]]; do
    case "$1" in
      -l | --cluster_location)
        arg_required "$@"
        CLUSTER_LOCATION="$2"
        shift 2
        ;;
      -p | --project_id)
        arg_required "$@"
        PROJECT_ID="$2"
        shift 2
        ;;
      -s | --service_account)
        arg_required "$@"
        SERVICE_ACCOUNT="$2"
        shift 2
        ;;
      -k | --key_file)
        arg_required "$@"
        KEY_FILE="$2"
        shift 2
        ;;
      -b | --build_id)
        arg_required "$@"
        BUILD_ID="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit
        ;;
      -*)
        fatal_with_usage "ERROR: Unknown option $1"
        ;;
      *)
        warn "WARNING: ignoring unknown input $1"
        shift
        ;;
    esac
  done

  check_exists "PROJECT_ID"
  check_exists "CLUSTER_LOCATION"

  if [[ -z "${BUILD_ID}" ]]; then # assume running locally
    set +e
    BUILD_ID="$(tr -dc a-z0-9 </dev/urandom | head -c 10)"
    set -e
    IS_LOCAL=0
  fi
}
#
### functions for interacting with the Google Cloud microservices demo

install_demo_app() {
  local NAMESPACE; NAMESPACE="$1"

  kubectl get ns "${NAMESPACE}" > /dev/null \
    || kubectl create namespace "${NAMESPACE}"

  kubectl -n "${NAMESPACE}" apply -f - <<EOF
$(get_demo_yaml "kubernetes" )
EOF

  anneal_k8s "${NAMESPACE}"
}

install_demo_app_istio_manifests() {
  local NAMESPACE; NAMESPACE="$1"

  kubectl label \
    namespace "${NAMESPACE}" \
    istio-injection=enabled \
    --overwrite

  kubectl -n "${NAMESPACE}" apply -f - <<EOF
$(get_demo_yaml "istio" )
EOF

  anneal_k8s "${NAMESPACE}"
}

label_with_revision() {
  local NAMESPACE; NAMESPACE="$1"
  local LABEL; LABEL="$2"

  kubectl label \
    namespace "${NAMESPACE}" \
    istio-injection- \
    "${LABEL}" \
    --overwrite
}

install_strict_policy() {
  local NAMESPACE; NAMESPACE="$1"

  kubectl -n "${NAMESPACE}" apply -f - <<EOF
apiVersion: "security.istio.io/v1beta1"
kind: "PeerAuthentication"
metadata:
  name: "default"
spec:
  mtls:
    mode: STRICT
EOF
}

get_demo_yaml() {
 curl -L "https://raw.githubusercontent.com/GoogleCloudPlatform/\
microservices-demo/v0.2.0/release/${1}-manifests.yaml"
}

verify_demo_app() {
  local IP; IP="$1"
  local PAGE
  local COUNT

  for _ in $(seq 1 30); do
    PAGE="$(curl "${IP}" -L -N -s || echo "")"
    COUNT="$(echo "${PAGE}" | grep -c Hipster || true)"
    { [[ "${COUNT}" -ne 0 ]] && break; } || sleep 10
  done
  if [[ "${COUNT}" -eq 0 ]]; then
    fail "Couldn't verify demo app is running on ${IP}"
    return 1
  else
    success "Verifed demo app is running on ${IP}"
    return 0
  fi
}

send_persistent_traffic() {
  local IP; IP="$1"
  local PAGE
  local COUNT
  while true; do
    PAGE="$(curl "${IP}" -L -N -s || echo "")"
    COUNT="$(echo "${PAGE}" | grep -c Hipster || true)"
    { [[ "${COUNT}" -eq 0 ]] && echo -e "Receive unexpected response from demo app:\n${PAGE}" && exit 1; } || sleep 1
  done
}
#
### functions for manipulating GKE clusters
create_working_cluster() {
  local PROJECT_ID; PROJECT_ID="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"

  gcloud beta container \
    --project "${PROJECT_ID}" \
    clusters create "${CLUSTER_NAME}" \
    --zone "${CLUSTER_LOCATION}" \
    --no-enable-basic-auth \
    --release-channel "regular" \
    --machine-type "e2-standard-4" \
    --image-type "COS" \
    --disk-type "pd-standard" \
    --disk-size "100" \
    --num-nodes "4" \
    --enable-stackdriver-kubernetes \
    --enable-ip-alias \
    --no-enable-master-authorized-networks \
    --addons HorizontalPodAutoscaling,HttpLoadBalancing \
    --enable-autoupgrade \
    --enable-autorepair

  KUBECONFIG="$(mktemp)"
  export KUBECONFIG

  gcloud container clusters get-credentials \
    "${CLUSTER_NAME}" \
    --project "${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}"
}

cleanup() {
  # remove traps so we don't infinite loop here
  trap - ERR

  local PROJECT_ID; PROJECT_ID="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"
  local NAMESPACE; NAMESPACE="$4"

  # first we need the ingress IPs to query against
  local KUBE_INGRESS; KUBE_INGRESS="$(kube_ingress "${NAMESPACE}")"
  local ISTIO_INGRESS; ISTIO_INGRESS="$(istio_ingress)"

  # next we need the info of the load balancer components
  local KUBE_LB_INFO; KUBE_LB_INFO="$(\
    gcloud compute \
    forwarding-rules list \
    --project="${PROJECT_ID}" \
    --format="get(name, region)" \
    --filter="IPAddress = ${KUBE_INGRESS}"
  )"
  local KUBE_LB_NAME; KUBE_LB_NAME="$(echo "${KUBE_LB_INFO}" | cut -f 1)"
  local REGION; REGION="$(echo "${KUBE_LB_INFO}" | sed 's|.*/||')"
  local ISTIO_LB_NAME; ISTIO_LB_NAME="$(\
    gcloud compute \
    forwarding-rules list \
    --project="${PROJECT_ID}" \
    --format="get(name)" \
    --filter="IPAddress = ${ISTIO_INGRESS}"
  )"

  # we don't care if any if the below fail, since a periodic cleanup script will
  # get them. they do seem to fail sporadically as sometimes load balancer
  # configurations will get deleted with resources and sometimes they don't.

  # delete the namespaces to get rid of the ingress objects
  remove_ns "${NAMESPACE}" || true
  remove_ns istio-system || true

  # remove the GCP load balancer components if they're still around
  gcloud compute forwarding-rules delete \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    "${KUBE_LB_NAME}" -q || true
  gcloud compute target-pools delete \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    "${KUBE_LB_NAME}" -q || true
  gcloud compute forwarding-rules delete \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    "${ISTIO_LB_NAME}" -q || true
  gcloud compute target-pools delete \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    "${ISTIO_LB_NAME}" -q || true

  # all of the resources are now deleted except for the cluster
  delete_cluster "${PROJECT_ID}" "${CLUSTER_NAME}" "${CLUSTER_LOCATION}"
}

delete_cluster() {
  # if this is running in CI delete async all of the time to keep it short
  if [[ "${IS_LOCAL}" -eq 1 ]]; then
    delete_cluster_async "$@"
    return "$?"
  fi
  local PROJECT_ID; PROJECT_ID="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"

  gcloud beta container \
    --project "${PROJECT_ID}" \
    clusters delete -q "${CLUSTER_NAME}" \
    --zone "${CLUSTER_LOCATION}"
}

delete_cluster_async() {
  local PROJECT_ID; PROJECT_ID="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"
  echo "Deleting ${CLUSTER_LOCATION}/${CLUSTER_NAME} async..." >&2

  gcloud beta container \
    --project "${PROJECT_ID}" \
    clusters delete -q "${CLUSTER_NAME}" \
    --zone "${CLUSTER_LOCATION}" \
    --async

  return "$?"
}
#
### kubectl convenience functions
auth_service_account() {
  gcloud auth activate-service-account \
    "${SERVICE_ACCOUNT}" \
    --project "${PROJECT_ID}" \
    --key-file="${KEY_FILE}"
}

anneal_k8s() {
  local NAMESPACE; NAMESPACE="$1"
  for _ in $(seq 1 30); do
    kubectl wait \
      --for=condition=available \
      deployments --all \
      -n "${NAMESPACE}" \
      --timeout=3m \
      && break \
      || echo "Retrying kubectl wait deployments..." \
      && sleep 1
  done

  for _ in $(seq 1 30); do
    kubectl wait \
      --for=condition=Ready \
      pods --all \
      -n "${NAMESPACE}" \
      --timeout=5s \
      && break \
      || echo "Retrying kubectl wait pods..." \
      && sleep 1
  done
}

roll() {
  local NAMESPACE; NAMESPACE="$1"

  kubectl -n "${NAMESPACE}" rollout restart deployment
  anneal_k8s "${NAMESPACE}"
}

kube_ingress() {
  warn "Running kubectl get service frontend-external..."
  for _ in $(seq 1 30); do
    IP=$(kubectl -n "${1}" \
      get service frontend-external \
      -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    [[ -n "${IP}" ]] && break || \
      warn "Retrying get service frontend-external..." \
      && sleep 2
  done
  echo "${IP}"
}

istio_ingress() {
  warn "Running kubectl get service istio-ingressgateway..."
  for _ in $(seq 1 30); do
    IP=$(kubectl -n "istio-system" \
      get service istio-ingressgateway \
      -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
    [[ -n "${IP}" ]] && break || \
      warn "Retrying get service istio-ingressgateway..." \
      && sleep 2
  done
  echo "${IP}"
}

does_istiod_exist(){
  local RETVAL; RETVAL=0;
  kubectl get service \
    --request-timeout='20s' \
    -n istio-system \
    istiod 1>/dev/null 2>/dev/null || RETVAL=$?
  return "${RETVAL}"
}

is_cluster_registered() {
  local PROJECT_ID; PROJECT_ID="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"

  local MEMBERSHIP_NAME
  MEMBERSHIP_NAME="gke-${PROJECT_ID}-${CLUSTER_LOCATION}-${CLUSTER_NAME}"
  local RETVAL; RETVAL=0;
  (gcloud container hub memberships list --project="${PROJECT_ID}" \
    | grep -q "${MEMBERSHIP_NAME}") || RETVAL=$?
  return "${RETVAL}"
}

remove_ns() {
  local NS; NS="$1"
  kubectl get ns "$NS" || return
  kubectl delete ns "$NS"
}
#
### functions for interacting with OSS Istio
install_oss_istio() {
  local NAMESPACE; NAMESPACE="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"
  local ISTIO_NAMESPACE; ISTIO_NAMESPACE="istio-system"
  readonly ISTIO_NAMESPACE

  echo "Downloading istioctl..."
  TMPDIR="$(mktemp -d)"
  pushd "${TMPDIR}"
  curl -L "https://github.com/istio/istio/releases/download/\
${OSS_VERSION}/istio-${OSS_VERSION}-linux-amd64.tar.gz" | tar xz

  ./istio-"${OSS_VERSION}"/bin/istioctl operator init
  popd
  rm -r "${TMPDIR}"

  kubectl create ns "${ISTIO_NAMESPACE}"

  kubectl apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: ${ISTIO_NAMESPACE}
  name: install-asm-test-${NAMESPACE}
spec:
  profile: default
EOF

  local I; I=0;
  local RETRIES; RETRIES=30; readonly RETRIES;
  echo -n "Waiting on Istio to finish installing..."
  until [[ "${I}" -eq "${RETRIES}" ]]; do
    sleep 10
    { [[ -n $(istio_ingress) ]] && break; } || echo -n "."
    ((++I))
  done
  echo "."
  if [[ "${I}" -eq "${RETRIES}" ]]; then
    fatal "Timed out waiting for Istio to finish installing."
  fi
  echo "Done."
}
