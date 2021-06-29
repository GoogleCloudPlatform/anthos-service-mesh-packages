KUBE_TAG_MAX_LEN=63; readonly KUBE_TAG_MAX_LEN

gen_install_params() {
  local CA; CA="$(context_get-option "CA")"

  local PARAM_BUILDER="-f ${OPERATOR_MANIFEST}"
  for yaml_file in $(context_list "istioctlFiles"); do
    PARAM_BUILDER="${PARAM_BUILDER} -f ${yaml_file}"
  done

  if [[ "${K8S_MINOR}" -eq 15 ]]; then
    PARAM_BUILDER="${PARAM_BUILDER} -f ${BETA_CRD_MANIFEST}"
  fi

  if [[ "${CA}" == "citadel" ]]; then
    PARAM_BUILDER="${PARAM_BUILDER} -f ${CITADEL_MANIFEST}"
  fi

  if ! is_gcp; then
    PARAM_BUILDER="${PARAM_BUILDER} -f ${OFF_GCP_MANIFEST}"
  fi

  echo "${PARAM_BUILDER}"
}
