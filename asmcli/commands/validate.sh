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

  validate_hub
  validate_dependencies
  validate_control_plane

  if [[ "${ONLY_VALIDATE}" -ne 0 ]]; then
    local VALIDATION_ERROR; VALIDATION_ERROR="$(context_get-option "VALIDATION_ERROR")"
    if [[ "${VALIDATION_ERROR}" -eq 0 ]]; then
      info "Successfully validated all requirements to install ASM."
      exit 0
    else
      warn "Please see the errors above."
      exit 2
    fi
  fi

  if only_enable; then
    info "Successfully performed specified --enable actions."
    exit 0
  fi
}

validate_dependencies() {
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local CA; CA="$(context_get-option "CA")"

  if can_modify_gcp_apis; then
    enable_gcloud_apis
  elif should_validate; then
    exit_if_apis_not_enabled
  fi

  if is_gcp; then
    if can_modify_gcp_components; then
      enable_workload_identity
      if ! is_stackdriver_enabled; then
        enable_stackdriver_kubernetes
      fi
      enable_service_mesh_feature
      if [[ "${CA}" == "managed_cas" ]]; then
        x_wait_for_gke_hub_api_enablement
        x_enable_workload_certificate_on_fleet "gkehub.googleapis.com"
      fi
    else
      exit_if_no_workload_identity
      exit_if_stackdriver_not_enabled
      if needs_service_mesh_feature; then
        exit_if_service_mesh_feature_not_enabled
      fi
    fi
  else
    enable_service_mesh_feature
  fi
  if can_register_cluster; then
    register_cluster
    exit_if_cluster_unregistered
    exit_if_hub_membership_is_empty
    local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
    if [[ "${CA}" == "managed_cas" ]]; then
      x_enable_workload_certificate_on_membership "gkehub.googleapis.com" "${FLEET_ID}" "${HUB_MEMBERSHIP_ID}"
      x_wait_for_enabling_workload_certificates "gkehub.googleapis.com" "${FLEET_ID}"
    fi
  elif should_validate && [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    exit_if_cluster_unregistered
  fi

  get_project_number "${FLEET_ID}"

  if can_modify_cluster_labels; then
    add_cluster_labels
  elif should_validate; then
    exit_if_cluster_unlabeled
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
  if is_autopilot; then
    validate_autopilot
    return
  fi
  if ! is_managed; then
    validate_in_cluster_control_plane
    return
  fi
  validate_managed_cni
}

validate_autopilot() {
  if ! is_managed; then
    fatal "Autopilot clusters are only supported with managed control plane."
  fi
}

validate_managed_cni() {
  if ! node_pool_wi_enabled; then
  { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

Nodepool Workload identity is not enabled or only partially enabled. CNI components will be installed but won't be used.
To use CNI, please follow:
  https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#migrate_applications_to
to migrate or update to a Workload Identity Enabled Node pool.

EOF
  fi
}
