validate_revision_label() {
  # Matches DNS label formats of RFC 1123
  local DNS_1123_LABEL_MAX_LEN; DNS_1123_LABEL_MAX_LEN=63;
  readonly DNS_1123_LABEL_MAX_LEN

  local DNS_1123_LABEL_FMT; DNS_1123_LABEL_FMT="^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?$";
  readonly DNS_1123_LABEL_FMT

  if [[ ${#REVISION_LABEL} -gt ${DNS_1123_LABEL_MAX_LEN} ]]; then
    fatal "Revision label cannot be longer than $DNS_1123_LABEL_MAX_LEN."
  fi

  if ! [[ "${REVISION_LABEL}" =~ ${DNS_1123_LABEL_FMT} ]]; then
    fatal "Revision label does not follow RFC 1123 formatting convention."
  fi
}

validate_hub() {
  if ! is_cluster_registered && ! can_register_cluster ; then
    context_set-option "USE_HUB_WIP" 0
  fi
}

### Environment validation functions ###
validate_environment() {
  if is_gcp; then
    validate_node_pool
  fi
  validate_k8s
  if is_gcp; then
    validate_expected_control_plane
  fi
  validate_no_ingress_gateway
}

validate_cli_dependencies() {
  local NOTFOUND; NOTFOUND="";
  local EXITCODE; EXITCODE=0;
  local CUSTOM_CA; CUSTOM_CA="$(context_get-option "CUSTOM_CA")"

  info "Checking installation tool dependencies..."
  while read -r dependency; do
    EXITCODE=0
    hash "${dependency}" 2>/dev/null || EXITCODE=$?
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="${dependency},${NOTFOUND}"
    fi
  done <<EOF
awk
$AGCLOUD
git
grep
jq
$AKUBECTL
sed
tr
head
csplit
EOF

  while read -r FLAG; do
    if [[ -z "${!FLAG}" ]]; then
      NOTFOUND="${FLAG},${NOTFOUND}"
    fi
  done <<EOF
AKUBECTL
AGCLOUD
EOF

  if [[ "${CUSTOM_CA}" -eq 1 ]]; then
    EXITCODE=0
    hash openssl 2>/dev/null || EXITCODE=$?
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="openssl,${NOTFOUND}"
    fi
  fi

  if [[ "${#NOTFOUND}" -gt 1 ]]; then
    NOTFOUND="$(strip_trailing_commas "${NOTFOUND}")"
    for dep in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "Dependency not found: ${dep}"
    done
    fatal "One or more dependencies were not found. Please install them and retry."
  fi

  local OS
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch
  if [[ "$(uname -m)" != "x86_64" ]]; then
    fatal "Installation is only supported on x86_64."
  fi
}

validate_gcp_resources() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  validate_cluster "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
}

validate_cluster() {
  local PROJECT_ID; PROJECT_ID="${1}"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="${2}"
  local CLUSTER_NAME; CLUSTER_NAME="${3}"

  local RESULT; RESULT=""

  RESULT="$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --filter="name = ${CLUSTER_NAME} AND location = ${CLUSTER_LOCATION}" \
    --format="value(name)" || true)"
  if [[ -z "${RESULT}" ]]; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Unable to find cluster ${CLUSTER_LOCATION}/${CLUSTER_NAME}.
Please verify the spelling and try again. To see a list of your clusters, in
this project, run:
  gcloud container clusters list --format='value(name,zone)' --project="${PROJECT_ID}"
EOF
  fi
}

validate_k8s() {
  K8S_MINOR="$(kubectl version -o json | jq .serverVersion.minor | sed 's/[^0-9]//g')"; readonly K8S_MINOR
  if [[ "${K8S_MINOR}" -lt 15 ]]; then
    fatal "ASM ${RELEASE} requires Kubernetes version 1.15+, found 1.${K8S_MINOR}"
  fi
}

#######
# validate_node_pool makes sure that the cluster meets ASM's minimum compute
# requirements
#######
validate_node_pool() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local MACHINE_CPU_REQ; MACHINE_CPU_REQ=4; readonly MACHINE_CPU_REQ;
  local TOTAL_CPU_REQ; TOTAL_CPU_REQ=8; readonly TOTAL_CPU_REQ;

  info "Confirming node pool requirements for ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  local ACTUAL_CPU
  ACTUAL_CPU="$(list_valid_pools "${MACHINE_CPU_REQ}" | \
      jq '.[] |
        (if .autoscaling.enabled then .autoscaling.maxNodeCount else .initialNodeCount end)
        *
        (.config.machineType / "-" | .[-1] | try tonumber catch 1)
        * (.locations | length)
      ' 2>/dev/null)" || true

  local MAX_CPU; MAX_CPU=0;
  for i in ${ACTUAL_CPU}; do
    MAX_CPU="$(( i > MAX_CPU ? i : MAX_CPU))"
  done

  if [[ "$MAX_CPU" -lt "$TOTAL_CPU_REQ" ]]; then
    { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

ASM requires you to have at least ${TOTAL_CPU_REQ} vCPUs in node pools whose
machine type is at least ${MACHINE_CPU_REQ} vCPUs.
${CLUSTER_LOCATION}/${CLUSTER_NAME} does not meet this requirement. ASM
may not function as expected.

EOF
  fi
}

validate_expected_control_plane(){
  info "Checking Istio installations..."
  check_no_istiod_outside_of_istio_system_namespace
}

check_no_istiod_outside_of_istio_system_namespace() {
  local IN_ANY_NAMESPACE IN_NAMESPACE
  IN_ANY_NAMESPACE="$(kubectl get deployment -A --ignore-not-found=true | grep -c istiod || true)";
  IN_NAMESPACE="$(kubectl get deployment -n istio-system --ignore-not-found=true | grep -c istiod || true)";

  if [ "$IN_ANY_NAMESPACE" -gt "$IN_NAMESPACE" ]; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
found istiod deployment outside of istio-system namespace. This installer
does not support that configuration.
EOF
  fi
}

validate_istio_version() {
  info "Checking existing Istio version(s)..."
  local VERSION_OUTPUT; VERSION_OUTPUT="$(retry 3 istioctl version -o json)"
  if [[ -z "${VERSION_OUTPUT}" ]]; then
    fatal "Couldn't validate existing Istio versions."
  fi
  local FOUND_VALID_VERSION; FOUND_VALID_VERSION=0
  for version in $(echo "${VERSION_OUTPUT}" | jq -r '.meshVersion[].Info.version' -r); do
    if [[ "$version" =~ ^$RELEASE_LINE || "$version" =~ ^$PREVIOUS_RELEASE_LINE ]]; then
      info "  $version (suitable for migration)"
      FOUND_VALID_VERSION=1
    else
      info "  $version (not suitable for migration)"
    fi
    if [[ "$version" =~ "asm" ]]; then
      fatal "Cannot migrate from version $version. Only migration from OSS Istio to the ASM distribution is supported."
    fi
  done
  if [[ "$FOUND_VALID_VERSION" -eq 0 ]]; then
    fatal "Migration requires an existing control plane in the ${RELEASE_LINE} line."
  fi
}

validate_asm_version() {
  info "Checking existing ASM version(s)..."
  local VERSION_OUTPUT; VERSION_OUTPUT="$(retry 3 istioctl version -o json)"
  if [[ -z "${VERSION_OUTPUT}" ]]; then
    fatal "Couldn't validate existing Istio versions."
  fi
  local FOUND_INVALID_VERSION; FOUND_INVALID_VERSION=0
  for VERSION in $(echo "${VERSION_OUTPUT}" | jq -r '.meshVersion[].Info.version'); do
    if ! [[ "${VERSION}" =~ "asm" ]]; then
      fatal "Cannot upgrade from version ${VERSION}. Only upgrades from ASM distributions are supported."
    fi

    if version_valid_for_upgrade "${VERSION}"; then
      info "  ${VERSION} (suitable for migration)"
    else
      info "  ${VERSION} (not suitable for migration)"
      FOUND_INVALID_VERSION=1
    fi
  done
  if [[ "$FOUND_INVALID_VERSION" -eq 1 ]]; then
    fatal "Upgrade requires all existing control planes to be between versions 1.$((MINOR-1)).0 (inclusive) and ${RELEASE} (exclusive)."
  fi
}

validate_ca_consistency() {
  local CURRENT_CA; CURRENT_CA="citadel"
  local CA; CA="$(context_get-option "CA")"

  if is_meshca_installed; then
    CURRENT_CA="mesh_ca"
  elif is_gcp_cas_installed; then
    CURRENT_CA="gcp_cas"
  fi

  info "CA already in use: ${CURRENT_CA}"

  if [[ -z "${CA}" ]]; then
    CA="${CURRENT_CA}"
    context_set-option "CA" "${CA}"
  fi

  if [[ "${CA}" != "${CURRENT_CA}" ]]; then
    fatal "CA cannot be switched while performing upgrade. Please use ${CURRENT_CA} as the CA."
  fi
}

validate_no_ingress_gateway() {
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  if [[ "${CUSTOM_OVERLAY}" =~ "legacy-default-ingressgateway" || \
        "${CUSTOM_OVERLAY}" =~ "iap-operator" ]]; then
    return
  fi

  local INGRESS_GATEWAY_SVC INGRESS_GATEWAY_DEP
  INGRESS_GATEWAY_SVC="$(kubectl get svc istio-ingressgateway -n istio-system || true)"
  INGRESS_GATEWAY_DEP="$(kubectl get deployments istio-ingressgateway -n istio-system || true)"
  if [[ -z "${INGRESS_GATEWAY_SVC}" && -z "${INGRESS_GATEWAY_DEP}" ]]; then
    return
  fi

  warn "We detected an ASM ingress gateway currently running in the cluster that"
  warn "will be disabled if installation continues. If this is not intended, please enter"
  warn "N and re-run the tool with the '--option legacy-default-ingressgateway'."
  if ! prompt_default_no "Continue?"; then fatal "Stopping installation at user request."; fi
}

exit_if_out_of_iam_policy() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local MEMBER_ROLES
  MEMBER_ROLES="$(gcloud projects \
    get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:$(local_iam_user)" \
    --format='value(bindings.role)')"

  if [[ "${MEMBER_ROLES}" = *"roles/owner"* ]]; then
    return
  fi

  local REQUIRED; REQUIRED="$(required_iam_roles)";

  local NOTFOUND; NOTFOUND="$(find_missing_strings "${REQUIRED}" "${MEMBER_ROLES}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for role in $(echo "${NOTFOUND}" | tr ',' '\n'); do
      warn "IAM role not enabled - ${role}"
    done
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
One or more IAM roles required to install ASM is missing. Please add
${GCLOUD_MEMBER} to the roles above, or run
the script with "--enable_gcp_iam_roles" to allow the script to add
them on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_apis_not_enabled() {
  local ENABLED; ENABLED="$(get_enabled_apis)";
  local REQUIRED; REQUIRED="$(required_apis)";
  local OLD_REQUIRED; OLD_REQUIRED="$(old_required_apis)";
  local NOTFOUND; NOTFOUND="";
  local OLD_NOTFOUND; OLD_NOTFOUND="";

  info "Checking required APIs..."
  NOTFOUND="$(find_missing_strings "${REQUIRED}" "${ENABLED}")"
  OLD_NOTFOUND="$(find_missing_strings "${OLD_REQUIRED}" "${ENABLED}")"

  if [[ -z "${OLD_NOTFOUND}" ]]; then
    if [[ -n "${NOTFOUND}" ]]; then
      warn "mesh.googleapis.com will be required in future versions of ASM."
    fi
    return;
  fi

  if [[ -n "${NOTFOUND}" ]]; then
    for api in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "API not enabled - ${api}"
    done
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
One or more APIs are not enabled. Please enable them and retry, or run the
script with the '--enable_gcp_apis' flag to allow the script to enable them on
your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_cluster_unlabeled() {
  local LABELS; LABELS="$(get_cluster_labels)";
  local REQUIRED; REQUIRED="$(mesh_id_label)";
  local NOTFOUND; NOTFOUND="$(find_missing_strings "${REQUIRED}" "${LABELS}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for label in $(echo "${NOTFOUND}" | tr ',' '\n'); do
      warn "Cluster label not found - ${label}"
    done
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
One or more required cluster labels were not found. Please label them and retry,
or run the script with the '--enable_cluster_labels' flag to allow the script
to enable them on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_cluster_unregistered() {
  if ! is_cluster_registered; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Cluster is not registered to a fleet. Please register the cluster and
retry, or run the script with the '--enable_registration' flag to allow
the script to register to the current project's fleet on your behalf.
EOF
  fi
}

exit_if_no_workload_identity() {
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  if ! is_workload_identity_enabled; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Workload identity is not enabled on ${CLUSTER_NAME}. Please enable it and
retry, or run the script with the '--enable_gcp_components' flag to allow
the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_stackdriver_not_enabled() {
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  if ! is_stackdriver_enabled; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Cloud Operations (Stackdriver)  is not enabled on ${CLUSTER_NAME}.
Please enable it and retry, or run the script with the
'--enable_gcp_components' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_not_cluster_admin() {
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  if ! is_user_cluster_admin; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Current user must have the cluster-admin role on ${CLUSTER_NAME}.
Please add the cluster role binding and retry, or run the script with the
'--enable_cluster_roles' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_service_mesh_feature_not_enabled() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  if ! is_service_mesh_feature_enabled; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
The service mesh feature is not enabled on project ${PROJECT_ID}.
Please run the script with the '--enable_gcp_components' flag to allow the
script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_istio_namespace_not_exists() {
  info "Checking for istio-system namespace..."
  if ! istio_namespace_exists; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
The istio-system namespace doesn't exist.
Please create the "istio-system" and retry, or run the script with the
'--enable_namespace_creation' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_cluster_registered_to_another_fleet() {
  local PROJECT_ID; PROJECT_ID="${1}"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="${2}"
  local CLUSTER_NAME; CLUSTER_NAME="${3}"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  local WANT
  WANT="//container.googleapis.com/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
  local LIST
  LIST="$(gcloud container hub memberships list --project "${FLEET_ID}" \
    --format=json | grep "${WANT}")"
  if [[ -z "${LIST}" ]]; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Cluster is already registered but not in the project ${FLEET_ID}.
EOF
  fi
}

enable_workload_identity(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  if is_workload_identity_enabled; then return; fi
  info "Enabling Workload Identity on ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  info "(This could take awhile, up to 10 minutes)"
  retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}" \
    --workload-pool="${WORKLOAD_POOL}"
}

enable_stackdriver_kubernetes(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  info "Enabling Stackdriver on ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}" \
    --enable-stackdriver-kubernetes
}

enable_service_mesh_feature() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  info "Enabling the service mesh feature..."

  retry 2 run_command gcloud container fleet mesh enable --project="${FLEET_ID}"
}

check_istio_deployed(){
  local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";

  info "Found ${ISTIOD_COUNT} deployment(s)."
  if [[ "$ISTIOD_COUNT" -eq 0 ]]; then
    warn_pause "no istiod deployment found. (Expected >=1.)"
  fi
}

check_istio_not_deployed(){
  local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
  if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
    { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

Install mode specified, but ${ISTIOD_COUNT} existing istiod deployment(s) found. (Expected 0.)
Installation may overwrite existing control planes with the same revision.

EOF
  fi
}

validate_args() {
  ### Option variables ###
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local PLATFORM; PLATFORM="$(context_get-option "PLATFORM")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local CA; CA="$(context_get-option "CA")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY="$(context_get-option "OPTIONAL_OVERLAY")"
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  local MANAGED_CERTIFICATES; MANAGED_CERTIFICATES="$(context_get-option "MANAGED_CERTIFICATES")"
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local LEGACY; LEGACY="$(context_get-option "LEGACY")"
  local MANAGED_SERVICE_ACCOUNT; MANAGED_SERVICE_ACCOUNT="$(context_get-option "MANAGED_SERVICE_ACCOUNT")"
  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local CUSTOM_CA; CUSTOM_CA="$(context_get-option "CUSTOM_CA")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CUSTOM_REVISION; CUSTOM_REVISION="$(context_get-option "CUSTOM_REVISION")"
  local WI_ENABLED; WI_ENABLED="$(context_get-option "WI_ENABLED")"
  local CONTEXT; CONTEXT="$(context_get-option "CONTEXT")"
  local KUBECONFIG_SUPPLIED; KUBECONFIG_SUPPLIED="$(context_get-option "KUBECONFIG_SUPPLIED")"
  local CHANNEL; CHANNEL="$(context_get-option "CHANNEL")"
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"

  if is_legacy && ! is_managed; then
      fatal "The --legacy option is only supported with managed control plane."
  fi

  if [[ -z "${CA}" ]]; then
    if [[ "${MANAGED_CERTIFICATES}" -eq 1 ]]; then
      CA="managed_cas"
    else
      CA="mesh_ca"
    fi
    context_set-option "CA" "${CA}"
  elif [[ "${MANAGED_CERTIFICATES}" -eq 1 ]]; then
    fatal "When --managed_certificates is enabled, the --ca option should not be specified."
  fi

  if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
    validate_revision_label
  fi

  if is_managed; then
    if [[ "${CA}" == "citadel" ]]; then
      fatal "Citadel is not supported with managed control plane."
    fi

    if [[ "${CUSTOM_CA}" -eq 1 ]]; then
      fatal "Specifying a custom CA with managed control plane is not supported."
    fi

    if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
      fatal "Specifying a revision label with managed control plane is not supported."
    fi

    if [[ -n "${CUSTOM_OVERLAY}" ]]; then
      fatal "Specifying a custom overlay file with managed control plane is not supported."
    fi
  fi

  if [[ -z "${PLATFORM}" ]]; then
    PLATFORM="gcp"
    context_set-option "PLATFORM" "gcp"
  fi

  case "${PLATFORM}" in
      gcp | multicloud);;
      *) fatal "PLATFORM must be one of 'gcp', 'multicloud'";;
  esac

  if [[ -n "${CHANNEL}" ]]; then
    case "${CHANNEL}" in
      regular | stable | rapid);;
      *) fatal "CHANNEL must be one of 'regular', 'stable', 'rapid'";;
    esac
  fi

  local MISSING_ARGS=0

  local CLUSTER_DETAIL_SUPPLIED=0
  local CLUSTER_DETAIL_VALID=1
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      CLUSTER_DETAIL_VALID=0
    else
      CLUSTER_DETAIL_SUPPLIED=1 # gke cluster param usage intended
    fi
  done <<EOF
PROJECT_ID
CLUSTER_LOCATION
CLUSTER_NAME
EOF

  # Script will not infer the intent between the 2 use cases in case both values are provided
  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    fatal_with_usage "Incompatible arguments. Kubeconfig cannot be used in conjunction with [--cluster_location|--cluster_name|--project_id]."
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${CLUSTER_DETAIL_VALID}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "Missing one or more required options for [CLUSTER_LOCATION|CLUSTER_NAME|PROJECT_ID]"
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 0 && "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "At least one of the following is required: 1) --kubeconfig or 2) --cluster_location, --cluster_name, --project_id"
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 && -z "${CONTEXT}" ]]; then
    # set CONTEXT to current-context in the KUBECONFIG
    # or fail-fast if current-context doesn't exist
    CONTEXT="$(kubectl config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      MISSING_ARGS=1
      warn "Missing current-context in the KUBECONFIG. Please provide context with --context flag or set a current-context in the KUBECONFIG"
    else
      context_set-option "CONTEXT" "${CONTEXT}"
    fi
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    info "Reading cluster information for ${CONTEXT}"
    local CONTEXT_CLUSTER;
    CONTEXT_CLUSTER="$(kubectl config get-contexts --no-headers | get_context_cluster)"
    validate_kubeconfig_context "${CONTEXT_CLUSTER}"
  fi

  if is_gcp; then
    # when no Fleet Id is provided, default to the cluster's project as the Fleet host.
    if [[ -z "${FLEET_ID}" ]]; then
      FLEET_ID="${PROJECT_ID}"
      context_set-option "FLEET_ID" "${FLEET_ID}"
    fi
  else
    # set Project Id to same as Fleet Id.
    # Project Id will be used to enable APIs if applicable.
    if [[ -n "${FLEET_ID}" ]]; then
      PROJECT_ID="${FLEET_ID}"
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
    fi
  fi

  if can_register_cluster && ! has_value "FLEET_ID"; then
    MISSING_ARGS=1
    warn "Missing FLEET_ID to register the cluster."
  fi

  case "${CA}" in
    citadel | mesh_ca | gcp_cas);;
    "")
      MISSING_ARGS=1
      warn "Missing value for CA"
      ;;
    *) fatal "CA must be one of 'citadel', 'mesh_ca', 'gcp_cas'";;
  esac

  if [[ "${CA}" = "gcp_cas" ]]; then
    validate_private_ca
  elif [[ "${CUSTOM_CA}" -eq 1 ]]; then
    validate_custom_ca
  fi

  if is_offline && [[ -z "${OUTPUT_DIR}" ]]; then
      MISSING_ARGS=1
      warn "Output directory must be specified in offline mode."
  fi

  if [[ "${MISSING_ARGS}" -ne 0 ]]; then
    fatal_with_usage "Missing one or more required options."
  fi

  while read -r FLAG; do
    if [[ "${!FLAG}" -ne 0 && "${!FLAG}" -ne 1 ]]; then
      fatal "${FLAG} must be 0 (off) or 1 (on) if set via environment variables."
    fi
    readonly "${FLAG}"
  done <<EOF
DRY_RUN
ENABLE_ALL
ENABLE_CLUSTER_ROLES
ENABLE_CLUSTER_LABELS
ENABLE_GCP_APIS
ENABLE_GCP_IAM_ROLES
ENABLE_GCP_COMPONENTS
ENABLE_REGISTRATION
MANAGED
LEGACY
DISABLE_CANONICAL_SERVICE
ONLY_VALIDATE
ONLY_ENABLE
VERBOSE
EOF

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_ROLES}" -eq 1 || \
    "${ENABLE_CLUSTER_LABELS}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 || \
    "${ENABLE_GCP_IAM_ROLES}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 || \
    "${ENABLE_REGISTRATION}" -eq 1  || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
      fatal "validation cannot be run with any --enable* flag"
    fi
  elif only_enable; then
    fatal "You must specify at least one --enable* flag with --only_enable"
  fi

  if [[ -n "$SERVICE_ACCOUNT" && -z "$KEY_FILE" || -z "$SERVICE_ACCOUNT" && -n "$KEY_FILE" ]]; then
    fatal "Service account and key file must be used together."
  fi

  # since we cd to a tmp directory, we need the absolute path for the key file
  # and yaml file
  if [[ -f "${KEY_FILE}" ]]; then
    KEY_FILE="$(apath -f "${KEY_FILE}")"
    readonly KEY_FILE
  elif [[ -n "${KEY_FILE}" ]]; then
    fatal "Couldn't find key file ${KEY_FILE}."
  fi

  local ABS_OVERLAYS; ABS_OVERLAYS=""
  while read -d ',' -r yaml_file; do
    if [[ -f "${yaml_file}" ]]; then
      ABS_OVERLAYS="$(apath -f "${yaml_file}"),${ABS_OVERLAYS}"
    elif [[ -n "${yaml_file}" ]]; then
      fatal "Couldn't find yaml file ${yaml_file}."
    fi
  done <<EOF
${CUSTOM_OVERLAY}
EOF
  CUSTOM_OVERLAY="${ABS_OVERLAYS}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"

  WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"; readonly WORKLOAD_POOL
}

validate_kubeconfig_context() {
  local CONTEXT_CLUSTER; CONTEXT_CLUSTER="${1}"

  # we don't get any info from the kubeconfig file if it's via the gateway
  if [[ "${CONTEXT_CLUSTER}" = connectgateway* ]]; then
    context_set-option "KC_VIA_CONNECT" 1
    return
  fi

  IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT_CLUSTER}
EOF
  if is_gcp; then
    context_set-option "PROJECT_ID" "${PROJECT_ID}"
    context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
    context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
  fi
}

arg_required() {
  if [[ ! "${2:-}" || "${2:0:1}" = '-' ]]; then
    fatal "Option ${1} requires an argument."
  fi
}

x_validate_install_args() {
  fatal "\"x install\" is now included with the --managed flag in the install command."

  ### Option variables ###
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local LEGACY; LEGACY="$(context_get-option "LEGACY")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local CA; CA="$(context_get-option "CA")"
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"
  local USE_VPCSC; USE_VPCSC="$(context_get-option "USE_VPCSC")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  local MANAGED_SERVICE_ACCOUNT; MANAGED_SERVICE_ACCOUNT="$(context_get-option "MANAGED_SERVICE_ACCOUNT")"
  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local CONTEXT; CONTEXT="$(context_get-option "CONTEXT")"
  local KUBECONFIG_SUPPLIED; KUBECONFIG_SUPPLIED="$(context_get-option "KUBECONFIG_SUPPLIED")"
  local CHANNEL; CHANNEL="$(context_get-option "CHANNEL")"

  if [[ -z "${CA}" ]]; then
    CA="mesh_ca"
    context_set-option "CA" "${CA}"
  fi

  local MISSING_ARGS=0

  local CLUSTER_DETAIL_SUPPLIED=0
  local CLUSTER_DETAIL_VALID=1
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      CLUSTER_DETAIL_VALID=0
    else
      CLUSTER_DETAIL_SUPPLIED=1 # gke cluster param usage intended
    fi
  done <<EOF
PROJECT_ID
CLUSTER_LOCATION
CLUSTER_NAME
EOF

  if [[ "${MANAGED}" -eq 0 ]]; then
    fatal "Currently only managed control plane installation is supported by experimental install."
  fi

  if [[ "${LEGACY}" -eq 1 ]]; then
    fatal "The legacy install subcommand is not available in the experimental install command."
  fi

  if [[ -n "${CHANNEL}" ]]; then
    case "${CHANNEL}" in
      regular | stable | rapid);;
      *) fatal "CHANNEL must be one of 'regular', 'stable', 'rapid'";;
    esac
  fi

  # Script will not infer the intent between the 2 use cases in case both values are provided
  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    fatal_with_usage "Incompatible arguments. Kubeconfig cannot be used in conjunction with [--cluster_location|--cluster_name|--project_id]."
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${CLUSTER_DETAIL_VALID}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "Missing one or more required options for [CLUSTER_LOCATION|CLUSTER_NAME|PROJECT_ID]"
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 0 && "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "At least one of the following is required: 1) --kubeconfig or 2) --cluster_location, --cluster_name, --project_id"
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 && -z "${CONTEXT}" ]]; then
    # set CONTEXT to current-context in the KUBECONFIG
    # or fail-fast if current-context doesn't exist
    CONTEXT="$(kubectl config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      MISSING_ARGS=1
      warn "Missing current-context in the KUBECONFIG. Please provide context with --context flag or set a current-context in the KUBECONFIG"
    else
      context_set-option "CONTEXT" "${CONTEXT}"
    fi
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    info "Reading cluster information for ${CONTEXT}"
    local CONTEXT_CLUSTER;
    CONTEXT_CLUSTER="$(kubectl config get-contexts --no-headers | get_context_cluster)"
    IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT_CLUSTER}
EOF
    if is_gcp; then
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
      context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
      context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
    fi
  fi

  if is_gcp; then
    # when no Fleet Id is provided, default to the cluster's project as the Fleet host.
    if [[ -z "${FLEET_ID}" ]]; then
      FLEET_ID="${PROJECT_ID}"
      context_set-option "FLEET_ID" "${FLEET_ID}"
    fi
  else
    # set Project Id to same as Fleet Id.
    # Project Id will be used to enable APIs if applicable.
    if [[ -n "${FLEET_ID}" ]]; then
      PROJECT_ID="${FLEET_ID}"
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
    fi
  fi

  if can_register_cluster && ! has_value "FLEET_ID"; then
    MISSING_ARGS=1
    warn "Missing FLEET_ID to register the cluster."
  fi

  if [[ "${MISSING_ARGS}" -ne 0 ]]; then
    fatal_with_usage "Missing one or more required options."
  fi

  while read -r FLAG; do
    if [[ "${!FLAG}" -ne 0 && "${!FLAG}" -ne 1 ]]; then
      fatal "${FLAG} must be 0 (off) or 1 (on) if set via environment variables."
    fi
    readonly "${FLAG}"
  done <<EOF
DRY_RUN
ENABLE_ALL
ENABLE_CLUSTER_LABELS
ENABLE_GCP_APIS
ENABLE_GCP_IAM_ROLES
ENABLE_GCP_COMPONENTS
ENABLE_REGISTRATION
USE_VPCSC
DISABLE_CANONICAL_SERVICE
ONLY_VALIDATE
ONLY_ENABLE
VERBOSE
EOF

  if [[ "${ENABLE_ALL}" -eq 1 || \
    "${ENABLE_CLUSTER_LABELS}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 || \
    "${ENABLE_GCP_IAM_ROLES}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 || \
    "${ENABLE_REGISTRATION}" -eq 1  || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
      fatal "validation cannot be run with any --enable* flag"
    fi
  elif only_enable; then
    fatal "You must specify at least one --enable* flag with --only_enable"
  fi

  if [[ -n "$SERVICE_ACCOUNT" && -z "$KEY_FILE" || -z "$SERVICE_ACCOUNT" && -n "$KEY_FILE" ]]; then
    fatal "Service account and key file must be used together."
  fi
}
