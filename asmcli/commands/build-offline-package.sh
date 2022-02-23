build-offline-package_subcommand() {
  build-offline-package_parse_args "$@"
  build-offline-package
}

build-offline-package() {
  set_up_local_workspace

  if needs_kpt; then
    download_kpt
  fi
  readonly AKPT

  if ! necessary_files_exist; then
    download_asm
  fi

  # kpt package initial downloads should be the same accross configuration
  # so no need to call should_download_kpt_package
  download_kpt_package

  build-offline-package_outro
}

build-offline-package_parse_args() {
  while [[ $# != 0 ]]; do
    case "${1}" in
      -D | --output_dir | --output-dir)
        arg_required "${@}"
        context_set-option "OUTPUT_DIR" "${2}"
        shift 2
        ;;
      -v | --verbose)
        context_set-option "VERBOSE" 1
        shift 1
        ;;
      -h | --help)
        context_set-option "PRINT_HELP" 1
        shift 1
        ;;
      --version)
        context_set-option "PRINT_VERSION" 1
        shift 1
        ;;
    esac
  done

  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  if [[ "${PRINT_HELP}" -eq 1 || "${PRINT_VERSION}" -eq 1 ]]; then
    if [[ "${PRINT_VERSION}" -eq 1 ]]; then
      version_message
    elif [[ "${VERBOSE}" -eq 1 ]]; then
      usage
    else
      usage_short
    fi
    exit
  fi
}

build-offline-package_outro() {
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"

  info ""
  info "$(starline)"
  istioctl version --remote=false
  info "$(starline)"
  info "The offline package download is now complete."

  info "The ASM package used for installation can be found at:"
  info "${OUTPUT_DIR}/asm"
  info "The version of istioctl that matches the installation can be found at:"
  info "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}"
  info "A symlink to the istioctl binary can be found at:"
  info "${OUTPUT_DIR}/istioctl"
  if ! is_managed; then
    info "The combined configuration generated for installation can be found at:"
    info "${OUTPUT_DIR}/${RAW_YAML}"
    info "The full, expanded set of kubernetes resources can be found at:"
    info "${OUTPUT_DIR}/${EXPANDED_YAML}"
  fi

  info "$(starline)"
}
