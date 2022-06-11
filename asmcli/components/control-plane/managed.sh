validate_managed_control_plane_legacy() {
  if can_modify_gcp_iam_roles; then
    bind_user_to_iam_policy "roles/meshconfig.admin" "$(local_iam_user)"
  fi
  if can_init_meshconfig; then
    if ! init_meshconfig_managed; then
      fatal "Couldn't initialize meshconfig, do you have the required permission resourcemanager.projects.setIamPolicy?"
    fi
  fi
}

call_runIstiod() {
  local PROJECT_ID; PROJECT_ID="${1}";
  local CLUSTER_LOCATION; CLUSTER_LOCATION="${2}";
  local CLUSTER_NAME; CLUSTER_NAME="${3}";
  local POST_DATA; POST_DATA="${4}";

  check_curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${POST_DATA}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
}

install_managed_control_plane() {
  local USE_MANAGED_CNI; USE_MANAGED_CNI="$(context_get-option "USE_MANAGED_CNI")"
  local CA; CA="$(context_get-option "CA")"
  if is_legacy; then
    provision_mcp_legacy
  else
    wait_for_cpr_crd
  fi

  if [[ "${USE_MANAGED_CNI}" -eq 0 ]]; then
    install_managed_cni_static
  fi

  if [[ "${CA}" = "gcp_cas" ]]; then
    install_managed_privateca
  fi

  if [[ "${CA}" == "managed_cas" ]]; then
    x_install_managed_cas_for_mcp
  fi

  install_managed_startup_config
}

provision_mcp_legacy() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  local POST_DATA; POST_DATA="{}";
  if [[ -n "${_CI_CLOUDRUN_IMAGE_HUB}" ]]; then
    POST_DATA="$(echo "${POST_DATA}" | jq -r --arg IMAGE "${_CI_CLOUDRUN_IMAGE_HUB}:${_CI_CLOUDRUN_IMAGE_TAG}" '. + {image: $IMAGE}')"
  fi

  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    POST_DATA="$(echo "${POST_DATA}" | jq -r --arg MEMBERSHIP "${HUB_IDP_URL/*projects/projects}" '. + {membership: $MEMBERSHIP}')"
  fi

  info "Provisioning control plane..."
  retry 2 call_runIstiod "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}" "${POST_DATA}"

  local MUTATING_WEBHOOK_URL
  MUTATING_WEBHOOK_URL=$(get_managed_mutating_webhook_url)

  local VALIDATION_URL
  # shellcheck disable=SC2001
  VALIDATION_URL="$(echo "${MUTATING_WEBHOOK_URL}" | sed 's/inject.*$/validate/g')"

  local CLOUDRUN_ADDR
  # shellcheck disable=SC2001
  CLOUDRUN_ADDR=$(echo "${MUTATING_WEBHOOK_URL}" | cut -d'/' -f3)

  kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
  kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"

  info "Configuring ASM managed control plane revision CRD..."
  context_append "kubectlFiles" "${CRD_CONTROL_PLANE_REVISION}"

  info "Configuring base installation for managed control plane..."
  context_append "kubectlFiles" "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  context_append "kubectlFiles" "${MANAGED_WEBHOOKS}"
}

wait_for_cpr_crd() {
  # `kubectl wait` for non-existent resources will return error directly so we wait in loop
  info "Waiting for the controlplanerevisions CRD to be installed by AFC. This could take a few minutes if cluster is newly registered."
  for i in {1..10}; do
    if kubectl wait --for condition=established --timeout=10s crd/controlplanerevisions.mesh.cloud.google.com 2>/dev/null; then
      break
    fi
    sleep 10
  done
}

install_managed_startup_config() {
  local ASM_OPTS=""
  local MCP_CONFIG

  for MCP_CONFIG in $(context_list "mcpOptions"); do
    ASM_OPTS="${MCP_CONFIG};${ASM_OPTS}"
  done

  cat >|mcp_configmap.yaml <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: asm-options
  namespace: istio-system
data:
  ASM_OPTS: "${ASM_OPTS}"
EOF

  context_append "kubectlFiles" "mcp_configmap.yaml"

}

install_managed_cni_static() {
  info "Configuring CNI..."
  if ! node_pool_wi_enabled; then
  { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

Nodepool Workload identity is not enabled or only partially enabled. CNI components will be installed but won't be used.
To use CNI, please follow:
  https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#migrate_applications_to 
to migrate or update to a Workload Identity Enabled Node pool.

EOF
  fi
  local ASM_OPTS
  ASM_OPTS="$(kubectl -n istio-system \
    get --ignore-not-found cm asm-options \
    -o jsonpath='{.data.ASM_OPTS}' || true)"

if node_pool_wi_enabled && [[ -z "${ASM_OPTS}" || "${ASM_OPTS}" != *"CNI=on"* && "${ASM_OPTS}" != *"CNI=off"* ]]; then
    context_append "mcpOptions" "CNI=on"
  else
    context_append "mcpOptions" "${ASM_OPTS}"
  fi
  context_append "kubectlFiles" "${MANAGED_CNI}"
}

install_managed_privateca() {
  info "Configuring GCP CAS with managed control plane..."

  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  context_append "mcpOptions" "CA=PRIVATECA"
  context_append "mcpOptions" "CAAddr=${CA_NAME}"
}

configure_managed_control_plane() {
  :
}

get_managed_mutating_webhook_url() {
  # Get the url for the most up to date channel that the cluster is using.
  local WEBHOOKS; WEBHOOKS="istiod-asm-managed-rapid istiod-asm-managed istiod-asm-managed-stable"
  local WEBHOOK_JSON

  for WEBHOOK in $WEBHOOKS; do
    if WEBHOOK_JSON="$(kubectl get mutatingwebhookconfiguration "${WEBHOOK}" -ojson)" ; then
      info "Using the following managed revision for validating webhook: ${WEBHOOK#'istiod-'}"
      echo "$WEBHOOK_JSON" | jq .webhooks[0].clientConfig.url -r
      return
    fi
  done

  fatal "Could not find managed config map."
}


init_meshconfig_managed() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig managed API..."
  local POST_DATA
  # When cluster local project is the same as the Hub Hosting Project
  # Initialize the project with Hub WIP and prepare istiod
  if [[ "${FLEET_ID}" == "${PROJECT_ID}" ]]; then
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"], "prepare_istiod": true}'
    init_meshconfig_curl "${POST_DATA}" "${FLEET_ID}"
  # When cluster local project is different from the Hub Hosting Project
  # Initialize the Hub Hosting project with Hub WIP
  # Initialize the cluster local project with Hub WIP & GKE WIP and prepare istiod
  else
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"]}'
    init_meshconfig_curl "${POST_DATA}" "${FLEET_ID}"
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog","'${PROJECT_ID}'.svc.id.goog"], "prepare_istiod": true}'
    init_meshconfig_curl "${POST_DATA}" "${PROJECT_ID}"
  fi
}
