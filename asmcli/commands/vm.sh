vm_subcommand() {
  parse_subcommand_for_vm "$@"
}

parse_subcommand_for_vm() {
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  case "${1}" in
    prepare-cluster)
      shift 1
      prepare_cluster_subcommand "${@}"
      ;;
    *)
      # TODO: update the help text.
      help_subcommand "${@}"
      ;;
  esac
}

prepare_cluster_subcommand() {
  parse_vm_args "${@}"
}

parse_vm_args() {
  if [[ "${*}" = '' ]]; then
    # TODO: update the short help text.
    usage_short >&2
    exit 2
  fi

  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  while [[ $# != 0 ]]; do
    case "${1}" in
      -l | --cluster_location | --cluster-location)
        arg_required "${@}"
        context_set-option "CLUSTER_LOCATION" "${2}"
        shift 2
        ;;
      -n | --cluster_name | --cluster-name)
        arg_required "${@}"
        context_set-option "CLUSTER_NAME" "${2}"
        shift 2
        ;;
      -p | --project_id | --project-id)
        arg_required "${@}"
        context_set-option "PROJECT_ID" "${2}"
        shift 2
        ;;
      --print_config | --print-config)
        context_set-option "PRINT_CONFIG" 1
        shift 1
        ;;
      -s | --service_account | --service-account)
        arg_required "${@}"
        context_set-option "SERVICE_ACCOUNT" "${2}"
        shift 2
        ;;
      -k | --key_file | --key-file)
        arg_required "${@}"
        context_set-option "KEY_FILE" "${2}"
        shift 2
        ;;
      -D | --output_dir | --output-dir)
        arg_required "${@}"
        context_set-option "OUTPUT_DIR" "${2}"
        shift 2
        ;;
      --dry_run | --dry-run)
        context_set-option "DRY_RUN" 1
        shift 1
        ;;
      --only_validate | --only-validate)
        context_set-option "ONLY_VALIDATE" 1
        shift 1
        ;;
      -v | --verbose)
        context_set-option "VERBOSE" 1
        shift 1
        ;;
      -h | --help)
        context_set-option "PRINT_HELP" 1
        shift 1
        ;;
      *)
        # TODO: update fatal help text.
        fatal_with_usage "Unknown option ${1}"
        ;;
    esac
  done
  readonly REVISION_LABEL

  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
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