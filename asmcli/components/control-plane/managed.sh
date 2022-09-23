install_managed_control_plane() {
  local USE_MANAGED_CNI; USE_MANAGED_CNI="$(context_get-option "USE_MANAGED_CNI")"
  local CA; CA="$(context_get-option "CA")"
  wait_for_cpr_crd

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
