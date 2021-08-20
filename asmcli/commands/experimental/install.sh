x_install_subcommand() {
  x_parse_install_args "${@}"
  context_set-option "MANAGED" 1
  context_set-option "PLATFORM" "gcp"
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

  install_control_plane_revision "${CR_CONTROL_PLANE_REVISION_REGULAR}" "${REVISION_LABEL_REGULAR}"
  install_control_plane_revision "${CR_CONTROL_PLANE_REVISION_RAPID}" "${REVISION_LABEL_RAPID}"
  install_control_plane_revision "${CR_CONTROL_PLANE_REVISION_STABLE}" "${REVISION_LABEL_STABLE}"

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
