print-config_subcommand() {
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"

  if [[ "${PRINT_CONFIG}" -eq 1 ]]; then
    if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
      populate_environ_info
    fi
    print_config >&3
    exit 0
  fi
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
