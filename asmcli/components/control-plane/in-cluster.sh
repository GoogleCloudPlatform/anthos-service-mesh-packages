validate_in_cluster_control_plane() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  if should_validate; then
    validate_environment
  fi
  if can_modify_gcp_components; then
    init_meshconfig
  elif should_validate && [[ "${FLEET_ID}" == "${PROJECT_ID}" ]]; then
    warn "There is no way to validate that the meshconfig API has been initialized."
    warn "This needs to happen once per GCP project. If the API has not been initialized"
    warn "for ${PROJECT_ID}, please re-run this tool with the --enable_gcp_components"
    warn "flag. Otherwise, installation will succeed but Anthos Service Mesh"
    warn_pause "will not function correctly."
  fi
  if can_modify_gcp_iam_roles; then
    bind_user_to_iam_policy "$(required_iam_roles)" "$(local_iam_user)"
  elif should_validate; then
    exit_if_out_of_iam_policy
  fi
}

configure_in_cluster_control_plane() {
  return
}

init_meshconfig() {
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig API..."
  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    populate_fleet_info
    local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
    info "Cluster has Membership ID ${HUB_MEMBERSHIP_ID} in the Hub of project ${FLEET_ID}"
    if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
      info "Skip initializing meshconfig API as the Hub is not hosted in the project ${PROJECT_ID}"
      return 0
    fi
    # initialize replaces the existing Workload Identity Pools in the IAM binding, so we need to support both Hub and GKE Workload Identity Pools
    local POST_DATA; POST_DATA='{"workloadIdentityPools":["'${FLEET_ID}'.hub.id.goog","'${FLEET_ID}'.svc.id.goog"]}'
    run_command curl --request POST --fail \
    --data "${POST_DATA}" -o /dev/null \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
  else
    run_command curl --request POST --fail \
    --data '' -o /dev/null \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    -K <(auth_header "$(get_auth_token)")
  fi
}
