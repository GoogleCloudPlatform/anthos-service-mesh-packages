validate_subcommand() {
  ### Preparation ###
  context_set-option "ONLY_VALIDATE" 1
  parse_args "${@}"
  validate_args
  prepare_environment

  ### Validate ###
  validate
}

validate() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"

  validate_dependencies
  validate_control_plane

  if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
    info "Successfully validated all requirements to install ASM in this environment."
    exit 0
  fi

  if only_enable; then
    info "Successfully performed specified --enable actions."
    exit 0
  fi
}

validate_dependencies() {
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if can_modify_gcp_apis; then
    enable_gcloud_apis
  elif should_validate; then
    exit_if_apis_not_enabled
  fi

  if is_gcp; then
    if can_modify_gcp_components; then
      enable_workload_identity
      enable_stackdriver_kubernetes
      if needs_service_mesh_feature; then
        enable_service_mesh_feature
      fi
    else
      exit_if_no_workload_identity
      exit_if_stackdriver_not_enabled
      if needs_service_mesh_feature; then
        exit_if_service_mesh_feature_not_enabled
      fi
    fi
  fi

  if can_register_cluster && is_gcp; then
    register_cluster
  elif should_validate && [[ "${USE_HUB_WIP}" -eq 1 || "${USE_VM}" -eq 1 ]]; then
    exit_if_cluster_unregistered
  fi

  get_project_number
  if is_gcp; then
    if can_modify_cluster_labels; then
      add_cluster_labels
    elif should_validate; then
      exit_if_cluster_unlabeled
    fi
  fi

  if can_modify_cluster_roles; then
    bind_user_to_cluster_admin
  elif should_validate; then
    exit_if_not_cluster_admin
  fi

  if can_create_namespace; then
    create_istio_namespace
  elif should_validate; then
    exit_if_istio_namespace_not_exists
  fi
}

validate_control_plane() {
  if is_managed; then
    # Managed must be able to set IAM permissions on a generated user, so the flow
    # is a bit different
    validate_managed_control_plane
  else
    validate_in_cluster_control_plane
  fi
}

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
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local CA; CA="$(context_get-option "CA")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if [[ "${CA}" == "citadel" && "${USE_HUB_WIP}" -eq 1 ]]; then
    fatal "Hub Workload Identity Pool is only supported for Mesh CA"
  fi

  if ! is_managed && [[ "${USE_VM}" -eq 1 && "${USE_HUB_WIP}" -eq 0 ]]; then
    fatal "Hub Workload Identity Pool is required to add VM workloads. Run the script with the -o hub-meshca option."
  fi

  if ! is_managed && [[ "${CA}" == "mesh_ca" && "${USE_HUB_WIP}" -eq 0 ]] && ( can_register_cluster && is_gcp || is_cluster_registered ) ; then
    info "Fleet workload identity pool is used as default for Mesh CA. "
    context_set-option "USE_HUB_WIP" 1
    local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY="$(context_get-option "OPTIONAL_OVERLAY")"
    OPTIONAL_OVERLAY="hub-meshca,${OPTIONAL_OVERLAY}"
    context_set-option "OPTIONAL_OVERLAY" "${OPTIONAL_OVERLAY}"
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
  validate_cluster
}

validate_cluster() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local RESULT; RESULT=""

  RESULT="$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --filter="name = ${CLUSTER_NAME} AND location = ${CLUSTER_LOCATION}" \
    --format="value(name)" || true)"
  if [[ -z "${RESULT}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
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
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
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
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
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
  local NOTFOUND; NOTFOUND="";

  info "Checking required APIs..."
  NOTFOUND="$(find_missing_strings "${REQUIRED}" "${ENABLED}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for api in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "API not enabled - ${api}"
    done
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
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
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
One or more required cluster labels were not found. Please label them and retry,
or run the script with the '--enable_cluster_labels' flag to allow the script
to enable them on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_cluster_unregistered() {
  if ! is_cluster_registered; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cluster is not registered to a fleet. Please register the cluster and
retry, or run the script with the '--enable_registration' flag to allow
the script to register to the current project's fleet on your behalf.
EOF
  fi
}

exit_if_no_workload_identity() {
  if ! is_workload_identity_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Workload identity is not enabled on ${CLUSTER_NAME}. Please enable it and
retry, or run the script with the '--enable_gcp_components' flag to allow
the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_stackdriver_not_enabled() {
  if ! is_stackdriver_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cloud Operations (Stackdriver)  is not enabled on ${CLUSTER_NAME}.
Please enable it and retry, or run the script with the
'--enable_gcp_components' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_not_cluster_admin() {
  if ! is_user_cluster_admin; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Current user must have the cluster-admin role on ${CLUSTER_NAME}.
Please add the cluster role binding and retry, or run the script with the
'--enable_cluster_roles' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

exit_if_service_mesh_feature_not_enabled() {
  if ! is_service_mesh_feature_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
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
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
The istio-system namespace doesn't exist.
Please create the "istio-namespace" and retry, or run the script with the
'--enable_namespace_creation' flag to allow the script to enable it on your behalf.
$(enable_common_message)
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
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Enabling the service mesh feature..."

  # IAM permission: gkehub.features.create
  retry 2 run_command curl -s -H "Content-Type: application/json" \
    -XPOST "https://gkehub.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/global/features?feature_id=servicemesh"\
    -d '{servicemesh_feature_spec: {}}' \
    -K <(auth_header "$(get_auth_token)")
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
