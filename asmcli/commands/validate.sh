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

  if can_modify_gcp_apis; then
    enable_gcloud_apis
  elif should_validate; then
    exit_if_apis_not_enabled
  fi

  if can_register_cluster; then
    register_cluster
  elif should_validate && [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    exit_if_cluster_unregistered
  fi

  if can_modify_gcp_components; then
    enable_workload_identity
    enable_stackdriver_kubernetes
  else
    exit_if_no_workload_identity
    exit_if_stackdriver_not_enabled
  fi

  get_project_number
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
  if is_managed; then
    # Managed must be able to set IAM permissions on a generated user, so the flow
    # is a bit different
    validate_managed_control_plane
  else
    validate_in_cluster_control_plane
  fi
}
