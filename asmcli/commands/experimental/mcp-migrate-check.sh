x_mcp_migrate_check() {
  x_parse_mcp_migrate_args "${@}"
  x_download_istioctl_tarball
  context_set-option "VERBOSE" 1

  local PARAMS
  PARAMS=""
  for yaml_file in $(context_list "istioctlFiles"); do
    PARAMS="${PARAMS} -f ${yaml_file}"
  done

  # shellcheck disable=SC2086
  x_istioctl asm mcp-migrate ${PARAMS}
}

x_parse_mcp_migrate_args() {
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  while [[ $# != 0 ]]; do
    case "${1}" in
      -f)
        arg_required "${@}"
        if [[ ! -f "${2}" ]]; then
          fatal "Couldn't find yaml file ${2}."
        fi
        context_append "istioctlFiles" "${2}"
        shift 2
        ;;
      *)
        fatal "Unknown option ${1}"
        ;;
    esac
  done
}

x_download_istioctl_tarball() {
  local OS
  case "$(uname)" in
    Linux ) OS="linux-amd64";;
    Darwin) OS="osx";;
    *     ) fatal "$(uname) is not a supported OS.";;
  esac

  info "Downloading ASM.."
  local TARBALL; TARBALL="istio-${RELEASE}-${OS}.tar.gz"
  if [[ -z "${_CI_ASM_PKG_LOCATION}" ]]; then
    curl -L "https://storage.googleapis.com/gke-release/asm/${TARBALL}" \
      | tar xz
  else
    local TOKEN; TOKEN="$(retry 2 gcloud auth print-access-token)"
    run_command curl -L "https://storage.googleapis.com/${_CI_ASM_PKG_LOCATION}/asm/${TARBALL}" \
      --header @- <<EOF | tar xz
Authorization: Bearer ${TOKEN}
EOF
  fi
}

x_istioctl() {
  run_command "$(istioctl_path)" "${@}"
}
