print-config_subcommand() {
  # make sure to redirect stdout as soon as possible if we're dumping the config
  exec 3>&1
  exec 1>&2

  ### Preparation ###
  context_init
  context_set-option "PRINT_CONFIG" 1
  parse_args "${@}"
  validate_args
  prepare_environment

  ### Validate ###
  validate

  if [[ "$(context_get-option "USE_VM")" -eq 1 ]]; then
    register_gce_identity_provider
  fi

  ### Configure ###
  configure_package
  post_process_istio_yamls

  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"

  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    populate_environ_info
  fi
  print_config >&3
}

print_config() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"

  if [[ "${MANAGED}" -eq 1 ]]; then
    cat "${MANAGED_MANIFEST}"
    return
  fi

  PARAMS="-f ${OPERATOR_MANIFEST}"
  for yaml_file in $(context_list-istio-yamls); do
    PARAMS="${PARAMS} -f ${yaml_file} "
  done
  # shellcheck disable=SC2086
  istioctl profile dump ${PARAMS}
}
