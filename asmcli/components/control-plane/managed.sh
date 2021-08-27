validate_managed_control_plane() {
  if can_modify_gcp_iam_roles; then
    bind_user_to_iam_policy "roles/meshconfig.admin" "$(local_iam_user)"
  fi
  if can_modify_at_all; then
    if ! init_meshconfig_managed; then
      fatal "Couldn't initialize meshconfig, do you have the required permission resourcemanager.projects.setIamPolicy?"
    fi
  fi
}

install_managed_control_plane() {
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
  retry 2 run_command curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${POST_DATA}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")

  local VALIDATION_URL; local CLOUDRUN_ADDR;
  read -r VALIDATION_URL CLOUDRUN_ADDR <<EOF
$(scrape_managed_urls)
EOF

  kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
  kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"

  info "Configuring ASM managed control plane revision CRD..."
  context_append "kubectlFiles" "${CRD_CONTROL_PLANE_REVISION}"

  info "Configuring base installation for managed control plane..."
  context_append "kubectlFiles" "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  context_append "kubectlFiles" "${MANAGED_WEBHOOKS}"

  local ASM_OPTS
  ASM_OPTS="$(kubectl -n istio-system \
    get --ignore-not-found cm asm-options \
    -o jsonpath='{.data.ASM_OPTS}' || true)"

  local USE_MCP_CNI; USE_MCP_CNI="$(context_get-option "USE_MCP_CNI")"
  local CNI; CNI="off"
  if [[ "${USE_MCP_CNI}" -eq 1 ]]; then
    info "Configuring CNI..."
    CNI="on"
  fi

  if [[ -z "${ASM_OPTS}" || "${ASM_OPTS}" != *"CNI=${CNI}"* ]]; then
    cat >mcp_configmap.yaml <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: asm-options
  namespace: istio-system
data:
  ASM_OPTS: "CNI=${CNI}"
EOF

    context_append "kubectlFiles" "mcp_configmap.yaml"
  fi

  if [[ "${USE_MCP_CNI}" -eq 1 ]]; then
    context_append "kubectlFiles" "${MANAGED_CNI}"
  fi
}

configure_managed_control_plane() {
  :
}

scrape_managed_urls() {
  local URL
  URL="$(kubectl get mutatingwebhookconfiguration istiod-asm-managed -ojson | jq .webhooks[0].clientConfig.url -r)"

  local VALIDATION_URL
  # shellcheck disable=SC2001
  VALIDATION_URL="$(echo "${URL}" | sed 's/inject.*$/validate/g')"

  local CLOUDRUN_ADDR
  # shellcheck disable=SC2001
  CLOUDRUN_ADDR=$(echo "${URL}" | cut -d'/' -f3)

  echo "${VALIDATION_URL} ${CLOUDRUN_ADDR}"
}


init_meshconfig_managed() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig managed API..."
  local POST_DATA
  POST_DATA='{"workloadIdentityPools":["'${PROJECT_ID}'.hub.id.goog","'${PROJECT_ID}'.svc.id.goog"], "prepare_istiod": true}'
  init_meshconfig_curl "${POST_DATA}" "${PROJECT_ID}"
  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"]}'
    init_meshconfig_curl "${POST_DATA}" "${FLEET_ID}"
  fi
}
