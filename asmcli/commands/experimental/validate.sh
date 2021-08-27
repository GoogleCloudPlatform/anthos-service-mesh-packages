x_validate_dependencies() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  if can_modify_gcp_apis; then
    enable_gcloud_apis
  elif should_validate; then
    exit_if_apis_not_enabled
  fi

  if can_register_cluster; then
    register_cluster
  elif should_validate; then
    exit_if_cluster_unregistered
  fi

  if can_modify_gcp_components; then
    enable_workload_identity
    if ! is_stackdriver_enabled; then
      enable_stackdriver_kubernetes
    fi
    enable_service_mesh_feature
  else
    exit_if_no_workload_identity
    exit_if_stackdriver_not_enabled
    exit_if_service_mesh_feature_not_enabled
  fi

  get_project_number "${FLEET_ID}"
  if can_modify_cluster_labels; then
    add_cluster_labels
  elif should_validate; then
    exit_if_cluster_unlabeled
  fi

  if can_create_namespace; then
    create_istio_namespace
  elif should_validate; then
    exit_if_istio_namespace_not_exists
  fi
}
