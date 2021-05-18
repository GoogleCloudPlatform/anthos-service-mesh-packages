validate_managed_control_plane() {
  return
}

configure_managed_control_plane() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"

  local CR_IMAGE_JSON; CR_IMAGE_JSON="";
  if [[ -n "${_CI_CLOUDRUN_IMAGE_HUB}" ]]; then
    CR_IMAGE_JSON="{\"image\": \"${_CI_CLOUDRUN_IMAGE_HUB}:${_CI_CLOUDRUN_IMAGE_TAG}\"}"
  fi
  retry 2 run_command curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${CR_IMAGE_JSON}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")

  local VALIDATION_URL; local CLOUDRUN_ADDR;
  read -r VALIDATION_URL CLOUDRUN_ADDR <<EOF
$(scrape_managed_urls)
EOF
  kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
  kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"
}
