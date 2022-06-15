has_value() {
  local VALUE; VALUE="$(context_get-option "${1}")"

  if [[ -n "${VALUE}" ]]; then return; fi

  if is_interactive; then
    VALUE="$(prompt_user_for_value "${1}")"
    echo "$VALUE"
  fi

  if [[ -n "${VALUE}" ]]; then
    context_set-option "${1}" "${VALUE}"
    return
  fi
  false
}

not_null() {
  local VALUE; VALUE="$1";
  [[ -n "${VALUE}" && "${VALUE}" != "null" ]]
}

is_managed() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"

  if [[ "${MANAGED}" -ne 1 ]]; then false; fi
}

is_legacy() {
  local LEGACY; LEGACY="$(context_get-option "LEGACY")"

  if [[ "${LEGACY}" -ne 1 ]]; then false; fi
}

is_interactive() {
  local NON_INTERACTIVE; NON_INTERACTIVE="$(context_get-option "NON_INTERACTIVE")"

  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then false; fi
}

is_gcp() {
  local PLATFORM; PLATFORM="$(context_get-option "PLATFORM")"
  if [[ "${PLATFORM}" == "gcp" ]]; then
    true
  else
    false
  fi
}

is_offline() {
  local OFFLINE; OFFLINE="$(context_get-option "OFFLINE")"

  if [[ "${OFFLINE}" -ne 1 ]]; then false; fi
}

using_connect_gateway() {
  local KVC; KVC="$(context_get-option "KC_VIA_CONNECT")"
  if [[ "${KVC}" -eq 1 ]]; then
    true
  else
    false
  fi
}

is_sa() {
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"

  if [[ -z "${SERVICE_ACCOUNT}" ]]; then false; fi
}

is_sa_impersonation() {
  local IMPERSONATE_USER; IMPERSONATE_USER="$(gcloud config get-value auth/impersonate_service_account)"
  if [[ -z "${IMPERSONATE_USER}" ]]; then false; fi
}

is_meshca_installed() {
  local INSTALLED_CA; INSTALLED_CA="$(kubectl -n istio-system get pod -l istio=ingressgateway \
    -o jsonpath='{.items[].spec.containers[].env[?(@.name=="CA_ADDR")].value}')"
  [[ "${INSTALLED_CA}" =~ meshca\.googleapis\.com ]] && return 0
}

is_gcp_cas_installed() {
  local INSTALLED_CA_PROVIDER
  INSTALLED_CA_PROVIDER="$(kubectl -n istio-system get pod -l istio=ingressgateway \
    -o jsonpath='{.items[].spec.containers[].env[?(@.name=="CA_PROVIDER")].value}')"
  [[ "${INSTALLED_CA_PROVIDER}" = "GoogleCAS" ]] && return 0
}

is_managed_cas_installed() {
  local INSTALLED_CA_PROVIDER
  INSTALLED_CA_PROVIDER="$(kubectl -n istio-system get pod -l istio=ingressgateway \
    -o jsonpath='{.items[].spec.containers[].env[?(@.name=="CA_PROVIDER")].value}')"
  [[ "${INSTALLED_CA_PROVIDER}" == "GkeWorkloadCertificate" ]] && return 0
}

is_cluster_registered() {
  info "Verifying cluster registration."

  if ! is_membership_crd_installed; then
    false
    return
  fi

  local MEMBERSHIP_DATA IDENTITY_PROVIDER
  MEMBERSHIP_DATA="$(retry 2 kubectl get memberships.hub.gke.io membership -ojson 2>/dev/null)"

  # expected value is the project id to which the cluster is registered
  IDENTITY_PROVIDER="$(echo "${MEMBERSHIP_DATA}" \
    | jq .spec.identity_provider \
    | sed -E 's/.*projects\/|\/locations.*//g')"
  if [[ -z "${IDENTITY_PROVIDER}" || "${IDENTITY_PROVIDER}" == 'null' ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cluster has memberships.hub.gke.io CRD but no identity provider specified.
Please ensure that the registered cluster has fleet workload identity enabled:
https://cloud.google.com/anthos/multicluster-management/fleets/workload-identity
EOF
  fi

  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  populate_fleet_info
  local MEMBERSHIP LOCATION WANT LIST G_DATA
  LOCATION="$(echo "${MEMBERSHIP_DATA}" \
    | jq -r .spec.owner.id \
    | sed -E 's/.*locations\/|\/memberships.*//g')"
  MEMBERSHIP="$(echo "${MEMBERSHIP_DATA}" \
    | jq -r .spec.owner.id \
    | sed -E 's/.*memberships\///g')"
  WANT="name.*projects/${FLEET_ID}/locations/${LOCATION}/memberships/${MEMBERSHIP}"
  G_DATA="$(gcloud container hub memberships list --project "${FLEET_ID}" --format=json)"
  LIST="$(echo "${G_DATA}" | grep "${WANT}")"

  local FLEET_HOST_PROJECT_NUMBER
  FLEET_HOST_PROJECT_NUMBER="$(gcloud projects describe "${FLEET_ID}" --format "value(projectNumber)")"

  if [[ "${IDENTITY_PROVIDER}" != "${FLEET_ID}" ]] && \
     [[ "${IDENTITY_PROVIDER}" != "${FLEET_HOST_PROJECT_NUMBER}" ]] || \
     [[ -z "${LIST}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cluster is registered in the project ${IDENTITY_PROVIDER}, but the required Fleet project is ${FLEET_ID}.
Please ensure that the cluster is registered to the ${FLEET_ID} project.
EOF
  fi

  if using_connect_gateway && is_gcp; then
    local ENDPOINT C_PROJ C_LOC C_NAME
    ENDPOINT="$(echo "${G_DATA}" | \
      jq -r '.[] | select(.name=="'"${WANT#??????}"'") | .endpoint.gkeCluster.resourceLink')"

    read -r C_PROJ C_LOC C_NAME <<EOF
$(echo "${ENDPOINT}" | sed 's/\/\/container.googleapis.com\/projects\/\(.*\)\/locations\/\(.*\)\/clusters\/\(.*\)$/\1 \2 \3/g')
EOF

    context_set-option "PROJECT_ID" "${C_PROJ}"
    context_set-option "CLUSTER_LOCATION" "${C_LOC}"
    context_set-option "CLUSTER_NAME" "${C_NAME}"
  fi

  info "Verified cluster is registered to ${IDENTITY_PROVIDER}"
}

is_workload_identity_enabled() {
  local WI_ENABLED; WI_ENABLED="$(context_get-option "WI_ENABLED")"
  if [[ "${WI_ENABLED}" -eq 1 ]]; then return; fi

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local ENABLED
  ENABLED="$(gcloud container clusters describe \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    "${CLUSTER_NAME}" \
    --format=json | \
    jq .workloadIdentityConfig)"

  if [[ "${ENABLED}" = 'null' ]]; then
    false;
  else
    WI_ENABLED=1;
    context_set-option "WI_ENABLED" "${WI_ENABLED}"
  fi
}

is_membership_crd_installed() {
  local OUTPUT
  if ! OUTPUT="$(retry 2 kubectl get crd memberships.hub.gke.io -ojsonpath="{..metadata.name}" 2>/dev/null)"; then
    false
    return
  fi

  if [[ "$(echo "${OUTPUT}" | grep -w -c memberships || true)" -eq 0 ]]; then
    false
    return
  fi

  if ! OUTPUT="$(retry 2 kubectl get memberships.hub.gke.io -ojsonpath="{..metadata.name}" 2>/dev/null)"; then
    false
    return
  fi

  if [[ "$(echo "${OUTPUT}" | grep -w -c membership || true)" -eq 0 ]]; then
    false
    return
  fi
}

is_stackdriver_enabled() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local ENABLED
  ENABLED="$(gcloud container clusters describe \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    "${CLUSTER_NAME}" \
    --format=json | \
    jq '.
    | [
    select(
      .loggingService == "logging.googleapis.com/kubernetes"
      and .monitoringService == "monitoring.googleapis.com/kubernetes")
      ] | length')"

  if [[ "${ENABLED}" -lt 1 ]]; then false; fi
}

is_user_cluster_admin() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local GCLOUD_USER; GCLOUD_USER="$(gcloud config get-value core/account)"
  local IAM_USER; IAM_USER="$(local_iam_user)"
  local ROLES
  ROLES="$(\
    kubectl get clusterrolebinding \
    --all-namespaces \
    -o jsonpath='{range .items[?(@.subjects[0].name=="'"${GCLOUD_USER}"'")]}[{.roleRef.name}]{end}'\
    2>/dev/null)"
  if echo "${ROLES}" | grep -q cluster-admin; then return; fi

  ROLES="$(gcloud projects \
    get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:${IAM_USER}" \
    --format='value(bindings.role)' 2>/dev/null)"
  if echo "${ROLES}" | grep -q roles/container.admin; then return; fi

  false
}

is_service_mesh_feature_enabled() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  local RESPONSE
  RESPONSE="$(run_command gcloud container fleet mesh describe --project="${FLEET_ID}")"

  if [[ "$(echo "${RESPONSE}" | jq -r '.featureState.lifecycleState' 2>/dev/null)" != "ENABLED" ]]; then
    false
  fi
}

should_validate() {
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if [[ "${PRINT_CONFIG}" -eq 1 || "${_CI_NO_VALIDATE}" -eq 1 ]] || only_enable; then false; fi
}

only_validate() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  if [[ "${ONLY_VALIDATE}" -eq 0 ]]; then false; fi
}

only_enable() {
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  if [[ "${ONLY_ENABLE}" -eq 0 ]]; then false; fi
}

can_modify_at_all() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if [[ "${ONLY_VALIDATE}" -eq 1 || "${PRINT_CONFIG}" -eq 1 ]]; then false; fi
}

can_modify_cluster_roles() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_ROLES}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_cluster_labels() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_LABELS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_apis() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_iam_roles() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_IAM_ROLES}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_components() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_init_meshconfig() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_MESHCONFIG_INIT; ENABLE_MESHCONFIG_INIT="$(context_get-option "ENABLE_MESHCONFIG_INIT")"

  if ! can_modify_at_all; then false; return; fi
  if can_modify_gcp_components; then return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_MESHCONFIG_INIT}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_register_cluster() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${USE_VM}" -eq 1 || "${ENABLE_REGISTRATION}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_create_namespace() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    true
  else
    false
  fi
}

needs_kpt() {
  if [[ -z "${AKPT}" ]]; then return; fi
  local KPT_VER
  KPT_VER="$(kpt version)"
  if [[ "${KPT_VER:0:1}" != "0" ]]; then return; fi
  false
}

needs_asm() {
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if only_enable; then false; return; fi

  if [[ "${PRINT_CONFIG}" -eq 1 ]] || can_modify_at_all || should_validate; then
    true
  else
    false
  fi
}

needs_service_mesh_feature() {
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if is_managed || [[ "${USE_VM}" -eq 1 ]]; then
    true
  else
    false
  fi
}

version_valid_for_upgrade() {
  local VERSION; VERSION=$1

  # if asm version found, pattern: 1.6.11-asm.1-586f900508ad482ed32b830dd15f6c54b32b93ed
  local VERSION_MAJOR VERSION_MINOR VERSION_POINT VERSION_REV
  IFS="." read -r VERSION_MAJOR VERSION_MINOR VERSION_POINT VERSION_REV <<EOF
${VERSION}
EOF
  VERSION_POINT="$(sed 's/-.*//' <<EOF
${VERSION_POINT}
EOF
)"
  VERSION_REV="$(sed 's/-.*//' <<EOF
${VERSION_REV}
EOF
)"
  if is_major_minor_invalid || is_minor_point_rev_invalid; then
    false
  fi
}

is_major_minor_invalid() {
  [[ "$VERSION_MAJOR" -ne 1 ]] && return 0
  [[ "$VERSION_MINOR" -lt $((MINOR-1))  ]] && return 0
  [[ "$VERSION_MINOR" -gt "$MINOR" ]] && return 0
}

is_minor_point_rev_invalid() {
  [[ "$VERSION_MINOR" -eq "$MINOR" ]] && is_point_rev_invalid && return 0
}

is_point_rev_invalid() {
  [[ "$VERSION_POINT" -gt "$POINT" ]] && return 0
  is_rev_invalid && return 0
}

is_rev_invalid() {
  [[ "$VERSION_POINT" -eq "$POINT" && "$VERSION_REV" -ge "$REV" ]] && return 0
}

istio_namespace_exists() {
  if [[ "${NAMESPACE_EXISTS}" -eq 1 ]]; then return; fi
  if [[ "$(retry 2 kubectl get ns | grep -c istio-system || true)" -eq 0 ]]; then
    false
  else
    NAMESPACE_EXISTS=1; readonly NAMESPACE_EXISTS
  fi
}

is_autopilot() {
  # TODO: wait till https://pkg.go.dev/google.golang.org/genproto/googleapis/container/v1#Cluster  
  # publish the `Autopilot` field
  # This is a temporary workaround to check if a cluster is Autopilot or GKE
  # This CRD will be installed only if the cluster is Autopilot
  if [[ "${IS_AUTOPILOT}" -eq 1 ]]; then return; fi
  if ! retry 2 kubectl get crd allowlistedworkloads.auto.gke.io 1>/dev/null 2>/dev/null; then
    false
  else
    IS_AUTOPILOT=1; readonly IS_AUTOPILOT
  fi
}

node_pool_wi_enabled(){
  # Autopilot clusters do not allow accessing/mutating the node pools
  # so we skip in such cases.
  if is_autopilot || [[ "${NODE_POOL_WI_ENABLED}" -eq 1 ]]; then 
    return
  fi
  local METADATA_CONFIG_MODE MACHINE_CPU_REQ
  # No CPU requirement for Managed ASM
  MACHINE_CPU_REQ=0
  METADATA_CONFIG_MODE="$(list_valid_pools "${MACHINE_CPU_REQ}" | \
      jq -r '.[] |
        .config.workloadMetadataConfig.mode
      ' 2>/dev/null)" || true
  if [[ -z "${METADATA_CONFIG_MODE}" ]]; then
    NODE_POOL_WI_ENABLED=0
    false
    return
  fi
  for metadata in ${METADATA_CONFIG_MODE}; do
    if [[ "${metadata}" != "GKE_METADATA" ]]; then
      NODE_POOL_WI_ENABLED=0
      false
      return
    fi
  done
  NODE_POOL_WI_ENABLED=1; readonly NODE_POOL_WI_ENABLED
}
