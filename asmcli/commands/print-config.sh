print-config_subcommand() {
  # make sure to redirect stdout as soon as possible if we're dumping the config
  exec 3>&1
  exec 1>&2

  ### Preparation ###
  context_set-option "PRINT_CONFIG" 1   # used by some validations
  parse_args "${@}"
  validate_args
  prepare_environment

  ### Validate ###
  validate

  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  if [[ "${USE_VM}" -eq 1 ]]; then
    register_gce_identity_provider
  fi

  ### Configure ###
  configure_package
  post_process_istio_yamls

  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    populate_fleet_info
  fi
  print_config >&3
}

# expects var PARAM already defined and populates it with the
# appropriate manifest overlays
init_install_params() {
  local CA; CA="$(context_get-option "CA")"

  PARAMS="-f ${OPERATOR_MANIFEST}"
  for yaml_file in $(context_list "istioctlFiles"); do
    PARAMS="${PARAMS} -f ${yaml_file}"
  done

  if [[ "${K8S_MINOR}" -eq 15 ]]; then
    PARAMS="${PARAMS} -f ${BETA_CRD_MANIFEST}"
  fi

  if [[ "${CA}" == "citadel" ]]; then
    PARAMS="${PARAMS} -f ${CITADEL_MANIFEST}"
  fi

  if ! is_gcp; then
    PARAMS="${PARAMS} -f ${OFF_GCP_MANIFEST}"
  fi
}

print_config() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"

  if [[ "${MANAGED}" -eq 1 ]]; then
    cat "${MANAGED_MANIFEST}"
    return
  fi

  local PARAMS
  init_install_params
  
  # shellcheck disable=SC2086
  istioctl profile dump ${PARAMS}
}
