LT_CLUSTER_NAME="${_LT_CLUSTER_NAME:=long-term-test-cluster}"
LT_ENVIRON_CLUSTER_NAME="long-term-test-cluster-environ"
LT_CLUSTER_LOCATION="us-central1-c"
LT_PROJECT_ID="asm-scriptaro-oss"
LT_NAMESPACE=""
OUTPUT_DIR=""

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
OSS_VERSION="${OSS_VERSION:=1.10.0}"; export OSS_VERSION;
OLD_OSS_VERSION="${OLD_OSS_VERSION:=1.9.5}"; export OLD_OSS_VERSION;
ISTIO_NAMESPACE="istio-system"; readonly ISTIO_NAMESPACE

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
  local MODE; MODE="${1}";
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
  ../install_asm ${KEY_FILE} ${SERVICE_ACCOUNT} \
    -l ${LT_CLUSTER_LOCATION} \
    -n ${LT_CLUSTER_NAME} \
    -p ${PROJECT_ID} \
    -m ${MODE} \
    -c ${CA} -v \
    --output-dir ${OUTPUT_DIR} \
    ${EXTRA_FLAGS}"
  # shellcheck disable=SC2086
  _CI_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../install_asm ${KEY_FILE} ${SERVICE_ACCOUNT} \
    -l "${LT_CLUSTER_LOCATION}" \
    -n "${LT_CLUSTER_NAME}" \
    -p "${PROJECT_ID}" \
    -m "${MODE}" \
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
  local MODE; MODE="${1}";
  local CA; CA="${2}";
  shift 2 # increment this if more arguments are added
  local EXTRA_FLAGS; EXTRA_FLAGS="${*}"

  date +"%T"

  if [[ -n "${SERVICE_ACCOUNT}" ]]; then
    echo "Authorizing service acount..."
    auth_service_account
  fi

  LT_NAMESPACE="$(uniq_name "${SCRIPT_NAME}" "${BUILD_ID}")"
  OUTPUT_DIR="$(mktemp -d)"

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

  mkfifo "${LT_NAMESPACE}"

  create_ns "${ISTIO_NAMESPACE}"

  # Test starts here
  echo "Installing ASM with MeshCA..."
  echo "_CI_REVISION_PREFIX=${LT_NAMESPACE} \
  ../install_asm ${KEY_FILE} ${SERVICE_ACCOUNT} \
    --kc ${KUBECONFIG} \
    -m ${MODE} \
    -c ${CA} -v \
    --output-dir ${OUTPUT_DIR} \
    ${EXTRA_FLAGS}"
  # shellcheck disable=SC2086
  CLUSTER_LOCATION="" \
  CLUSTER_NAME="" \
  PROJECT_ID="" \
  _CI_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../install_asm ${KEY_FILE} ${SERVICE_ACCOUNT} \
    --kc "${KUBECONFIG}" \
    -m "${MODE}" \
    -c "${CA}" -v \
    --output-dir "${OUTPUT_DIR}" \
    ${EXTRA_FLAGS} ${_EXTRA_FLAGS} 2>&1 | tee "${LT_NAMESPACE}" &


  LABEL="$(grep -o -m 1 'istio.io/rev=\S*' "${LT_NAMESPACE}")"
  REV="$(echo "${LABEL}" | cut -f 2 -d =)"
  echo "Got label ${LABEL}"
  rm "${LT_NAMESPACE}"

  sleep 5
  echo "Installing Istio manifests for demo app..."
  install_demo_app_istio_manifests "${LT_NAMESPACE}"

  echo "Performing a rolling restart of the demo app..."
  label_with_revision "${LT_NAMESPACE}" "${LABEL}"
  roll "${LT_NAMESPACE}"

  # MCP doesn't install Ingress
  if [[ "${EXTRA_FLAGS}" = *--managed* ]]; then
    return
  fi

  local SUCCESS; SUCCESS=0;
  echo "Getting istio ingress IP..."
  GATEWAY="$(istio_ingress)"
  echo "Got ${GATEWAY}"
  echo "Verifying demo app via Istio ingress..."
  set +e
  verify_demo_app "${GATEWAY}" || SUCCESS=1
  set -e

  if [[ "${SUCCESS}" -eq 1 ]]; then
    echo "Failed to verify, restarting and trying again..."
    roll "${LT_NAMESPACE}"

    echo "Getting istio ingress IP..."
    GATEWAY="$(istio_ingress)"
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

# pass in the NAME of the service account
create_service_account() {
  local SVC_ACCT_NAME; SVC_ACCT_NAME="$1"
  echo "Creating service account ${SVC_ACCT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com..."
  gcloud iam service-accounts create "${SVC_ACCT_NAME}" --project "${PROJECT_ID}"
}

# pass in the EMAIL of the service account
delete_service_account() {
  local SVC_ACCT_EMAIL; SVC_ACCT_EMAIL="$1"
  echo "Deleting service account ${SVC_ACCT_EMAIL}..."
  gcloud iam service-accounts delete "${SVC_ACCT_EMAIL}" \
    --quiet --project "${PROJECT_ID}"
}

create_workload_service_account() {
  local WORKLOAD_SERVICE_ACCOUNT_NAME="vm-${LT_NAMESPACE}"
  WORKLOAD_SERVICE_ACCOUNT="${WORKLOAD_SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  create_service_account "${WORKLOAD_SERVICE_ACCOUNT_NAME}"
}

create_new_instance_template() {
  local SOURCE_INSTANCE_TEMPLATE="$1"
  local TEMPLATE_NAME="$2"
  
  echo "Creating instance template ${INSTANCE_TEMPLATE_NAME}..."
  if [[ "${CREATE_FROM_SOURCE}" -eq 0 ]]; then
    echo "ASM_REVISION_PREFIX=${LT_NAMESPACE} \
        ../asm_vm create_gce_instance_template ${TEMPLATE_NAME} \
        ${KEY_FILE} ${SERVICE_ACCOUNT} \
        --cluster_location ${LT_CLUSTER_LOCATION} \
        --cluster_name ${LT_CLUSTER_NAME} \
        --project_id ${PROJECT_ID} \
        --workload_name ${WORKLOAD_NAME} \
        --workload_namespace ${LT_NAMESPACE}"
    
    ASM_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../asm_vm create_gce_instance_template "${TEMPLATE_NAME}" \
      ${KEY_FILE} ${SERVICE_ACCOUNT} \
      --cluster_location "${LT_CLUSTER_LOCATION}" \
      --cluster_name "${LT_CLUSTER_NAME}" \
      --project_id "${PROJECT_ID}" \
      --workload_name "${WORKLOAD_NAME}" \
      --workload_namespace "${LT_NAMESPACE}"
  else
    echo "ASM_REVISION_PREFIX=${LT_NAMESPACE} \
        ../asm_vm create_gce_instance_template ${TEMPLATE_NAME} \
        ${KEY_FILE} ${SERVICE_ACCOUNT} \
        --cluster_location ${LT_CLUSTER_LOCATION} \
        --cluster_name ${LT_CLUSTER_NAME} \
        --project_id ${PROJECT_ID} \
        --workload_name ${WORKLOAD_NAME} \
        --workload_namespace ${LT_NAMESPACE} \
        --source_instance_template ${SOURCE_INSTANCE_TEMPLATE}"
    
    ASM_REVISION_PREFIX="${LT_NAMESPACE}" \
    ../asm_vm create_gce_instance_template "${TEMPLATE_NAME}" \
      ${KEY_FILE} ${SERVICE_ACCOUNT} \
      --cluster_location "${LT_CLUSTER_LOCATION}" \
      --cluster_name "${LT_CLUSTER_NAME}" \
      --project_id "${PROJECT_ID}" \
      --workload_name "${WORKLOAD_NAME}" \
      --workload_namespace "${LT_NAMESPACE}" \
      --source_instance_template "${SOURCE_INSTANCE_TEMPLATE}"
  fi
}

create_source_instance_template() {
  echo "Creating source instance template ${SOURCE_INSTANCE_TEMPLATE_NAME}..."
  local image_project="${1:-debian-cloud}"
  local image_family="${2:-debian-10}"

  # Create an instance template with a metadata entry and a label entry
  gcloud compute instance-templates create "${SOURCE_INSTANCE_TEMPLATE_NAME}" \
    --project "${PROJECT_ID}" \
    --metadata="testKey=testValue" \
    --labels="testlabel=testvalue" \
    --service-account="${WORKLOAD_SERVICE_ACCOUNT}" \
    --image-project="${image_project}" \
    --image-family="${image_family}"
}

create_custom_source_instance_template() {
  echo "Creating custom source instance template ${CUSTOM_SOURCE_INSTANCE_TEMPLATE_NAME}..."

  gcloud compute instances create "${CUSTOM_IMAGE_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${CUSTOM_IMAGE_LOCATION}"
  gcloud compute instances stop "${CUSTOM_IMAGE_NAME}" \
    --project "${PROJECT_ID}" \
    --zone "${CUSTOM_IMAGE_LOCATION}"
  gcloud compute images create "${CUSTOM_IMAGE_NAME}" \
    --project "${PROJECT_ID}" \
    --source-disk="${CUSTOM_IMAGE_NAME}" \
    --source-disk-zone="${CUSTOM_IMAGE_LOCATION}"

  # Create an instance template with a metadata entry, a label entry AND A CUO
  gcloud compute instance-templates create "${CUSTOM_SOURCE_INSTANCE_TEMPLATE_NAME}" \
    --project "${PROJECT_ID}" \
    --metadata="testKey=testValue" \
    --labels="testlabel=testvalue" \
    --image-project="${PROJECT_ID}" \
    --image="${CUSTOM_IMAGE_NAME}" \
    --service-account="${WORKLOAD_SERVICE_ACCOUNT}"

  gcloud compute instances delete "${CUSTOM_IMAGE_NAME}" --zone "${CUSTOM_IMAGE_LOCATION}" \
    --project "${PROJECT_ID}" --quiet
}

verify_instance_template() {
  echo "Verifying instance template ${INSTANCE_TEMPLATE_NAME}..."

  local VAL
  VAL="$(gcloud compute instance-templates list --project "${PROJECT_ID}" \
    --filter="name=${INSTANCE_TEMPLATE_NAME}" --format="value(name)")"
  if [[ -z "${VAL}" ]]; then
    fail "Cannot find instance template ${INSTANCE_TEMPLATE_NAME} in the project."
    return 1
  fi

  local SERVICE_PROXY_CONFIG
  SERVICE_PROXY_CONFIG="$(gcloud compute instance-templates describe "${INSTANCE_TEMPLATE_NAME}" \
    --project "${PROJECT_ID}" --format=json | \
    jq -r '.properties.metadata.items[] | select(.key == "gce-service-proxy").value')"

  if [[ "$(echo "${SERVICE_PROXY_CONFIG}" | jq -r '."asm-config".proxyMetadata."POD_NAMESPACE"')" \
    != "${LT_NAMESPACE}" ]]; then
    fail "Instance template created does not set the workload namespace to ${LT_NAMESPACE}."
    return 1
  fi

  if [[ "$(echo "${SERVICE_PROXY_CONFIG}" | jq -r '."asm-config".proxyMetadata."ISTIO_META_WORKLOAD_NAME"')" \
    != "${WORKLOAD_NAME}" ]]; then
    fail "Instance template created does not set the workload name to ${WORKLOAD_NAME}."
    return 1
  fi

  if [[ "$(echo "${SERVICE_PROXY_CONFIG}" | jq -r '."asm-config".proxyMetadata."CANONICAL_SERVICE"')" \
    != "${WORKLOAD_NAME}" ]]; then
    fail "Instance template created does not set the canonical service name to ${WORKLOAD_NAME}."
    return 1
  fi

  if [[ "$(echo "${SERVICE_PROXY_CONFIG}" | jq -r '."asm-config".proxyMetadata."SERVICE_ACCOUNT"')" \
    != "${WORKLOAD_SERVICE_ACCOUNT}" ]]; then
    fail "Instance template created does not set workload service account to ${WORKLOAD_SERVICE_ACCOUNT}."
    return 1
  fi
}

verify_instance_template_with_source() {
  verify_instance_template

  local KEYVAL
  KEYVAL="$(gcloud compute instance-templates describe "${INSTANCE_TEMPLATE_NAME}" \
    --project "${PROJECT_ID}" --format=json | \
    jq -r '.properties.metadata.items[] | select(.key == "testKey").value')"
  if [[ "${KEYVAL}" != "testValue" ]]; then
    fail "Custom metadata does not have a key testKey with value testValue."
    return 1
  fi

  local LABELVAL
  LABELVAL="$(gcloud compute instance-templates describe "${INSTANCE_TEMPLATE_NAME}" \
    --project "${PROJECT_ID}" --format=json | jq -r '.properties.labels.testlabel')"
  if [[ -z "${LABELVAL}" ]] || [[ "${LABELVAL}" == 'null' ]]; then
    fail "Label testlabel:testvalue is not found in the label field."
    return 1
  fi
}

cleanup_workload_service_account() {
  delete_service_account "${WORKLOAD_SERVICE_ACCOUNT}"
}

delete_instance_template() {
  local TEMPLATE; TEMPLATE="$1"
  echo "Deleting instance template ${TEMPLATE}..."
  gcloud compute instance-templates delete "${TEMPLATE}" \
    --quiet --project "${PROJECT_ID}"
}

cleanup_old_workload_service_accounts() {
  echo "Cleaning up all existing service accounts for VM workload..."
  while read -r email; do
    if [[ -n "${email}" ]]; then
      gcloud iam service-accounts delete "${email}" --quiet --project "${LT_PROJECT_ID}"
    fi
  done <<EOF
$(gcloud iam service-accounts list --filter="email~^vm-" --format="value(email)" --project "${LT_PROJECT_ID}")
EOF
}

cleanup_old_instance_templates() {
  echo "Cleaning up all instance templates for VM workload..."
  while read -r it; do
    if [[ -n "${it}" ]]; then
      gcloud compute instance-templates delete "${it}" --quiet --project "${LT_PROJECT_ID}"
    fi
  done <<EOF
$(gcloud compute instance-templates list --filter="name~^vm-" --format="value(name)" --project "${LT_PROJECT_ID}")
EOF
}

cleanup_old_instances() {
  echo "Cleaning up all instance for VM workload..."
  while read -r it; do
    if [[ -n "${it}" ]]; then
      gcloud compute instances delete "${it}" --quiet --project "${LT_PROJECT_ID}"
    fi
  done <<EOF
$(gcloud compute instances list --filter="name~^vm-" --format="value(name)" --project "${LT_PROJECT_ID}")
EOF
}

cleanup_old_images() {
  echo "Cleaning up all images for VM workload..."
  while read -r it; do
    if [[ -n "${it}" ]]; then
      gcloud compute images delete "${it}" --quiet --project "${LT_PROJECT_ID}"
    fi
  done <<EOF
$(gcloud compute images list --filter="name~^vm-" --format="value(name)" --project "${LT_PROJECT_ID}")
EOF
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
