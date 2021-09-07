x_install_subcommand() {
  x_parse_install_args "${@}"
  context_set-option "PLATFORM" "gcp"
  context_set-option "EXPERIMENTAL" 1
  x_validate_install_args
  prepare_environment

  x_validate_dependencies
  x_configure_package
  x_install
}

x_install() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"

  # TODO: MANAGED_CNI install should go here, if necessary

  # `kubectl wait` for non-existent resources will return error directly so we wait in loop
  info "Wait for the controlplanerevisions CRD to be installed by AFC. This should take a few minutes if cluster is newly registered."
  for i in {1..10}; do
    if kubectl wait --for condition=established --timeout=10s crd/controlplanerevisions.mesh.cloud.google.com 2>/dev/null; then
      break
    fi
    sleep 10
  done

  install_control_plane_revisions

  outro
  info "Successfully installed ASM."
  return 0
}

x_configure_package() {
  if [[ -n "${_CI_ASM_IMAGE_LOCATION}" ]]; then
    kpt cfg set asm anthos.servicemesh.hub "${_CI_ASM_IMAGE_LOCATION}"
  fi
  if [[ -n "${_CI_ASM_IMAGE_TAG}" ]]; then
    kpt cfg set asm anthos.servicemesh.tag "${_CI_ASM_IMAGE_TAG}"
  fi
}
