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
