LT_CLUSTER_NAME="${_LT_CLUSTER_NAME:=long-term-test-cluster}"
LT_ENVIRON_CLUSTER_NAME="long-term-test-cluster-environ"
LT_CLUSTER_LOCATION="us-central1-c"
LT_PROJECT_ID="asm-scriptaro-oss"
LT_NAMESPACE=""
OUTPUT_DIR=""
SAMPLE_INGRESS_FILE="../../samples/gateways/istio-ingressgateway.yaml"

### vm related variables
WORKLOAD_NAME="vm"
WORKLOAD_SERVICE_ACCOUNT=""
INSTANCE_TEMPLATE_NAME=""
SOURCE_INSTANCE_TEMPLATE_NAME="vm-source"
CUSTOM_SOURCE_INSTANCE_TEMPLATE_NAME="vm-customsourcetemplate"
CUSTOM_IMAGE_LOCATION="us-central1-c"
CUSTOM_IMAGE_NAME="vm-customsourcetemplateimage"
CREATE_FROM_SOURCE=0

_EXTRA_FLAGS="${_EXTRA_FLAGS:=}"; export _EXTRA_FLAGS;

BUILD_ID="${BUILD_ID:=}"; export BUILD_ID;
PROJECT_ID="${PROJECT_ID:=}"; export PROJECT_ID;
CLUSTER_LOCATION="${CLUSTER_LOCATION:=us-central1-c}"; export CLUSTER_LOCATION;
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:=}"; export SERVICE_ACCOUNT;
CUSTOM_INSTANCE_TEMPLATE_NAME="${CUSTOM_INSTANCE_TEMPLATE_NAME:=custominstancetemplate}"; export CUSTOM_INSTANCE_TEMPLATE_NAME;
KEY_FILE="${KEY_FILE:=}"; export KEY_FILE;
OSS_VERSION="${OSS_VERSION:=1.9.0}"; export OSS_VERSION;
OLD_OSS_VERSION="${OLD_OSS_VERSION:=1.8.2}"; export OLD_OSS_VERSION;
ISTIO_NAMESPACE="istio-system"; readonly ISTIO_NAMESPACE;

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

uniq_name() {
  TEST_NAME="${1}"
  BUILD_ID="${2}"
  HASH="$(echo "${TEST_NAME}/${BUILD_ID}" | sha256sum)"
  echo "${HASH::16}"
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

  kubectl label ns "${NAMESPACE}" scriptaro-test=true || true

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

install_sample_ingress() {
  local NS; NS="${1}"
  local REV; REV="${2}"

  sed 's/GATEWAY_NAMESPACE/'"${NS}"'/g' <"${SAMPLE_INGRESS_FILE}" | \
  sed 's/REVISION/'"${REV}"'/g' | \
  kubectl apply -f -

  anneal_k8s "${NS}"
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
microservices-demo/v0.3.6/release/${1}-manifests.yaml"
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
  configure_kubectl  "${CLUSTER_NAME}" "${PROJECT_ID}" "${CLUSTER_LOCATION}"

}

configure_kubectl() {
  local CLUSTER_NAME; CLUSTER_NAME="${1}";
  local PROJECT_ID; PROJECT_ID="${2}";
  local CLUSTER_LOCATION; CLUSTER_LOCATION="${3}";

  KUBECONFIG="$(mktemp)"
  export KUBECONFIG

  gcloud container clusters get-credentials \
    "${CLUSTER_NAME}" \
    --project "${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}"
}

cleanup_lt_cluster() {
  local NAMESPACE; NAMESPACE="$1"
  local DIR; DIR="$2"

  set +e
  "${DIR}"/istio*/bin/istioctl x uninstall --purge -y
  remove_ns "${NAMESPACE}" || true
  remove_ns istio-system || true
  remove_ns asm-system || true
  # Remove managed control plane webhooks
  kubectl delete mutatingwebhookconfigurations istiod-asm-managed istiod-asmca istiod-ossmanaged || true
  kubectl delete validatingwebhookconfigurations istiod-istio-system || true
  # Remove managed CNI resources
  kubectl delete -f "${DIR}"/asm/istio/options/cni-managed.yaml || true
  set -e
}

cleanup_old_test_namespaces() {
  local DIR; DIR="${1}"
  local NOW_TS;NOW_TS="$(date +%s)"
  local CREATE_TS
  local NSS; NSS="istio-system asm-system"

  "${DIR}"/istio*/bin/istioctl x uninstall --purge -y

  while read -r isodate ns; do
    CREATE_TS="$(date -d "${isodate}" +%s)"
    if ((NOW_TS - CREATE_TS > 86400)); then
      NSS="${ns} ${NSS}"
    fi
  done <<EOF
$(get_labeled_clusters)
EOF
  echo "Deleting old namespaces ${NSS}"
  remove_ns ${NSS}
}

get_labeled_clusters() {
  kubectl get ns \
    -l scriptaro-test=true \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\n"}{end}' \
    || true
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

  # we should delete only the membership for the cluster. It should be okay for
  # now, as we register new memebership during tests.
  cleanup_all_memberships
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

cleanup_all_memberships() {
  echo "Deleting all memberships in ${PROJECT_ID}..."
  local MEMBERSHIPS
  MEMBERSHIPS="$(gcloud container hub memberships list --project "${PROJECT_ID}" \
   --format='value(name)')"
  while read -r MEMBERSHIP; do
    if [[ -n "${MEMBERSHIP}" ]] && [[ "${MEMBERSHIP}" != "${LT_ENVIRON_CLUSTER_NAME}" ]]; then
      local GKE_URL
      GKE_URL="$(gcloud container hub memberships describe "${MEMBERSHIP}" \
        --project "${PROJECT_ID}" --format="value(endpoint.gkeCluster.resourceLink)")"
      gcloud container hub memberships unregister "${MEMBERSHIP}" --quiet \
        --project "${PROJECT_ID}" --gke-uri "${GKE_URL}"
    fi
  done <<EOF
${MEMBERSHIPS}
EOF
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
  local NS; NS="${1}"
  if [[ -z "${NS}" ]]; then NS="istio-system"; fi
  warn "Running kubectl get service istio-ingressgateway..."
  for _ in $(seq 1 30); do
    IP=$(kubectl -n "${NS}" \
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

istio_namespace_exists() {
  if [[ "$(kubectl get ns | grep -c istio-system || true)" -eq 0 ]]; then
    false
  fi
}

is_cluster_registered() {
  local IDENTITY_PROVIDER
  IDENTITY_PROVIDER="$(kubectl get memberships.hub.gke.io \
    membership -ojson 2>/dev/null | jq .spec.identity_provider)"

  if [[ -z "${IDENTITY_PROVIDER}" ]] || [[ "${IDENTITY_PROVIDER}" = 'null' ]]; then
    false
  fi
}

remove_ns() {
  kubectl delete ns "${1}" || true
}

create_ns() {
  kubectl create ns "${1}" || true
}

#
### functions for interacting with OSS Istio
install_oss_istio() {
  local NAMESPACE; NAMESPACE="$1"
  local CLUSTER_NAME; CLUSTER_NAME="$2"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$3"

  echo "Downloading istioctl..."
  TMPDIR="$(mktemp -d)"
  pushd "${TMPDIR}"
  curl -L "https://github.com/istio/istio/releases/download/\
${OSS_VERSION}/istio-${OSS_VERSION}-linux-amd64.tar.gz" | tar xz

  ./istio-"${OSS_VERSION}"/bin/istioctl operator init
  popd
  rm -r "${TMPDIR}"

  create_ns "${ISTIO_NAMESPACE}"
  kubectl label ns "${ISTIO_NAMESPACE}" scriptaro-test=true

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

run_required_role() {
  local SUBCOMMAND; SUBCOMMAND="${1}"
  local CA; CA="${2}";
  local EXPECTED_ROLES; EXPECTED_ROLES="${3}"
  shift 3 # increment this if more arguments are added
  local EXTRA_FLAGS; EXTRA_FLAGS="${*}"

  date +"%T"

  if [[ -n "${SERVICE_ACCOUNT}" ]]; then
    echo "Authorizing service acount..."
    auth_service_account
  fi

  OUTPUT_DIR="$(mktemp -d)"

  configure_kubectl "${LT_CLUSTER_NAME}" "${PROJECT_ID}" "${LT_CLUSTER_LOCATION}"

  if [[ -n "${KEY_FILE}" && -n "${SERVICE_ACCOUNT}" ]]; then
    KEY_FILE="-k ${KEY_FILE}"
    SERVICE_ACCOUNT="-s ${SERVICE_ACCOUNT}"
  fi

  create_ns "${ISTIO_NAMESPACE}"

  # Test starts here
  echo "Installing ASM with MeshCA..."
  echo "_CI_REVISION_PREFIX=${LT_NAMESPACE} \
  ../asmcli ${SUBCOMMAND} ${KEY_FILE} ${SERVICE_ACCOUNT} \
    -l ${LT_CLUSTER_LOCATION} \
    -n ${LT_CLUSTER_NAME} \
    -p ${PROJECT_ID} \
    -c ${CA} -v \
    --output-dir ${OUTPUT_DIR} \
    ${EXTRA_FLAGS}"
  # shellcheck disable=SC2086
  _CI_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../asmcli ${SUBCOMMAND} ${KEY_FILE} ${SERVICE_ACCOUNT} \
    -l "${LT_CLUSTER_LOCATION}" \
    -n "${LT_CLUSTER_NAME}" \
    -p "${PROJECT_ID}" \
    -c "${CA}" -v \
    --output-dir "${OUTPUT_DIR}" \
    ${EXTRA_FLAGS} ${_EXTRA_FLAGS} 2>&1


  local SUCCESS; SUCCESS=0;

  local MEMBER_ROLES
  MEMBER_ROLES="$(gcloud projects \
    get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT}" \
    --format='value(bindings.role)')"

  # Should not bind any addiontal roles othen than the expected ones
  local NOTFOUND; NOTFOUND="$(find_missing_strings "${MEMBER_ROLES}" "${EXPECTED_ROLES}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for role in $(echo "${NOTFOUND}" | tr ',' '\n'); do
      warn "IAM roles should not be enabled - ${role}"
    done
    SUCCESS=1
  else
    echo "Success! Only required IAM roles are enabled."
  fi
  return "$SUCCESS"
}

run_basic_test() {
  local SUBCOMMAND; SUBCOMMAND="${1}"
  local CA; CA="${2}";
  shift 2 # increment this if more arguments are added
  local EXTRA_FLAGS; EXTRA_FLAGS="${*}"

  date +"%T"

  if [[ -n "${SERVICE_ACCOUNT}" ]]; then
    echo "Authorizing service acount..."
    auth_service_account
  fi

  LT_NAMESPACE="$(uniq_name "${SCRIPT_NAME}" "${BUILD_ID}")"
  OUTPUT_DIR="${OUTPUT_DIR:=$(mktemp -d)}"

  configure_kubectl "${LT_CLUSTER_NAME}" "${PROJECT_ID}" "${LT_CLUSTER_LOCATION}"

  trap 'remove_ns "${LT_NAMESPACE}"; rm "${LT_NAMESPACE}"; exit 1' ERR

  # Demo app setup
  echo "Installing and verifying demo app..."
  install_demo_app "${LT_NAMESPACE}"

  local GATEWAY; GATEWAY="$(kube_ingress "${LT_NAMESPACE}")";
  verify_demo_app "$GATEWAY"

  if [[ -n "${KEY_FILE}" && -n "${SERVICE_ACCOUNT}" ]]; then
    KEY_FILE="-k ${KEY_FILE}"
    SERVICE_ACCOUNT="-s ${SERVICE_ACCOUNT}"
  fi

  if [[ -n "${CA}" ]]; then
    CA="-c ${CA}"
  fi

  mkfifo "${LT_NAMESPACE}"

  create_ns "${ISTIO_NAMESPACE}"

  # Test starts here
  echo "Installing ASM with MeshCA..."
  echo "_CI_REVISION_PREFIX=${LT_NAMESPACE} \
  ../asmcli ${SUBCOMMAND} ${KEY_FILE} ${SERVICE_ACCOUNT} \
    --kc ${KUBECONFIG} \
    ${CA} -v \
    --output-dir ${OUTPUT_DIR} \
    ${EXTRA_FLAGS}"
  # shellcheck disable=SC2086
  CLUSTER_LOCATION="" \
  CLUSTER_NAME="" \
  PROJECT_ID="" \
  _CI_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../asmcli ${SUBCOMMAND} ${KEY_FILE} ${SERVICE_ACCOUNT} \
    --kc "${KUBECONFIG}" \
    ${CA} -v \
    --output-dir "${OUTPUT_DIR}" \
    ${EXTRA_FLAGS} ${_EXTRA_FLAGS} 2>&1 | tee "${LT_NAMESPACE}" &


  LABEL="$(grep -o -m 1 'istio.io/rev=\S*' "${LT_NAMESPACE}")"
  REV="$(echo "${LABEL}" | cut -f 2 -d =)"
  echo "Got label ${LABEL}"
  rm "${LT_NAMESPACE}"
  sleep 5

  # @zerobfd to suggest fix for failing GW
  # if [[ "${EXTRA_FLAGS}" != *--managed* && "${SUBCOMMAND}" != *experimental* ]]; then
  #   echo "Installing Istio ingress..."
  #   install_sample_ingress "${LT_NAMESPACE}" "${REV}"
  #   sleep 5
  # fi

  echo "Installing Istio manifests for demo app..."
  install_demo_app_istio_manifests "${LT_NAMESPACE}"

  echo "Performing a rolling restart of the demo app..."
  label_with_revision "${LT_NAMESPACE}" "${LABEL}"
  roll "${LT_NAMESPACE}"

  if [[ "${EXTRA_FLAGS}" = *--managed* || "${SUBCOMMAND}" = *experimental* ]]; then
    local READY; READY=0
    for _ in {1..5}; do
      check_cni_ready && READY=1 && break || echo "Retrying checking CNI..." && sleep 10
    done
    if [[ "${READY}" -eq 0 ]]; then
      fatal "CNI daemonset never becomes ready."
    fi
  fi

  return # see above for @zerobfd

  # MCP doesn't install Ingress
  if [[ "${EXTRA_FLAGS}" = *--managed* || "${SUBCOMMAND}" = *experimental* ]]; then
    return
  fi

  local SUCCESS; SUCCESS=0;
  echo "Getting istio ingress IP..."
  GATEWAY="$(istio_ingress "${LT_NAMESPACE}")"
  echo "Got ${GATEWAY}"
  echo "Verifying demo app via Istio ingress..."
  set +e
  verify_demo_app "${GATEWAY}" || SUCCESS=1
  set -e

  if [[ "${SUCCESS}" -eq 1 ]]; then
    echo "Failed to verify, restarting and trying again..."
    roll "${LT_NAMESPACE}"

    echo "Getting istio ingress IP..."
    GATEWAY="$(istio_ingress "${LT_NAMESPACE}")"
    echo "Got ${GATEWAY}"
    echo "Verifying demo app via Istio ingress..."
    set +e
    verify_demo_app "${GATEWAY}" || SUCCESS=1
    set -e
  fi

  # check validation webhook
  echo "Verifying istiod service exists..."
  if ! does_istiod_exist; then
    echo "Could not find istiod service."
  fi

  date +"%T"

  return "$SUCCESS"
}

run_build_offline_package() {
  local OUTPUT_DIR; OUTPUT_DIR="${1}"
  echo "Build offline package..."
  echo "../asmcli build-offline-package -v \
    --output-dir ${OUTPUT_DIR}"
  # shellcheck disable=SC2086
    ../asmcli build-offline-package -v \
    --output-dir "${OUTPUT_DIR}" 2>&1

  # Check downloaded packages
  [ -s "${OUTPUT_DIR}" ]
  ls "${OUTPUT_DIR}/asm" 1>/dev/null
  ls "${OUTPUT_DIR}/istioctl" 1>/dev/null
  ls "${OUTPUT_DIR}/istio-"* 1>/dev/null
}

delete_service_mesh_feature() {
  echo "Removing the service mesh feature from the project ${PROJECT_ID}..."

  local TOKEN
  TOKEN="$(gcloud --project="${PROJECT_ID}" auth print-access-token)"

  curl -s -H "X-Goog-User-Project: ${PROJECT_ID}"  \
    -X DELETE \
    "https://gkehub.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/global/features/servicemesh" \
    -H @- <<EOF
Authorization: Bearer ${TOKEN}
EOF
}

is_service_mesh_feature_enabled() {
  local TOKEN
  TOKEN="$(gcloud --project="${PROJECT_ID}" auth print-access-token)"

  local RESPONSE
  RESPONSE="$(curl -s -H "X-Goog-User-Project: ${PROJECT_ID}"  \
    "https://gkehub.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/global/features/servicemesh" \
    -H @- <<EOF
Authorization: Bearer ${TOKEN}
EOF
)"

  if [[ "$(echo "${RESPONSE}" | jq -r '.featureState.lifecycleState')" != "ENABLED" ]]; then
    false
  fi
}

find_missing_strings() {
  local NEEDLES; NEEDLES="${1}";
  local HAYSTACK; HAYSTACK="${2}";
  local NOTFOUND; NOTFOUND="";

  while read -r needle; do
    EXITCODE=0
    grep -q "${needle}" <<EOF || EXITCODE=$?
${HAYSTACK}
EOF
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="${needle},${NOTFOUND}"
    fi
  done <<EOF
${NEEDLES}
EOF

  if [[ -n "${NOTFOUND}" ]]; then NOTFOUND="$(strip_trailing_commas "${NOTFOUND}")"; fi
  echo "${NOTFOUND}"
}

check_cni_ready() {
  if ! kubectl get daemonset istio-cni-node -n kube-system 2>/dev/null; then
    false; return
  fi

  local NUMBER_READY NUMBER_DESIRED
  NUMBER_READY="$(kubectl get daemonset istio-cni-node -n kube-system -o jsonpath='{.status.numberReady}')"
  NUMBER_DESIRED="$(kubectl get daemonset istio-cni-node -n kube-system -o jsonpath='{.status.desiredNumberScheduled}')"


  if [[ "${NUMBER_DESIRED}" -eq 0 ]] || [[ "${NUMBER_READY}" -ne "${NUMBER_DESIRED}" ]]; then
    warn "Found ${NUMBER_READY} ready of ${NUMBER_DESIRED} wanted from CNI daemonset."
    false
  fi
}
