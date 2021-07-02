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

init_meshconfig_managed() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig managed API..."
  run_command curl --request POST --fail \
    --data '{"prepare_istiod": true}' \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
}
