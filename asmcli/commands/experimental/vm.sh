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
  validate_vm_args

  if is_sa; then
    auth_service_account
  fi

  validate_vm_dependencies
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

  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  # TODO: update help message.
  if [[ "${PRINT_HELP}" -eq 1 ]]; then
    if [[ "${VERBOSE}" -eq 1 ]]; then
      usage
    else
      usage_short
    fi
    exit
  fi
}

validate_vm_args() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"

  local MISSING_ARGS; MISSING_ARGS=0
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      MISSING_ARGS=1
      warn "Missing value for ${REQUIRED_ARG}"
    fi
    readonly "${REQUIRED_ARG}"
  done <<EOF
CLUSTER_LOCATION
CLUSTER_NAME
PROJECT_ID
EOF

  if [[ "${MISSING_ARGS}" -ne 0 ]]; then
    fatal_with_usage "Missing one or more required options."
  fi

  while read -r FLAG; do
    if [[ "${!FLAG}" -ne 0 && "${!FLAG}" -ne 1 ]]; then
      fatal "${FLAG} must be 0 (off) or 1 (on) if set via environment variables."
    fi
    readonly "${FLAG}"
  done <<EOF
DRY_RUN
ONLY_VALIDATE
VERBOSE
EOF

  if [[ -n "$SERVICE_ACCOUNT" && -z "$KEY_FILE" || -z "$SERVICE_ACCOUNT" && -n "$KEY_FILE" ]]; then
    fatal "Service account and key file must be used together."
  fi

  # since we cd to a tmp directory, we need the absolute path for the key file
  # and yaml file
  if [[ -f "${KEY_FILE}" ]]; then
    KEY_FILE="$(apath -f "${KEY_FILE}")"
    readonly KEY_FILE
  elif [[ -n "${KEY_FILE}" ]]; then
    fatal "Couldn't find key file ${KEY_FILE}."
  fi
}

validate_vm_cli_dependencies() {
  local NOTFOUND; NOTFOUND="";
  local EXITCODE; EXITCODE=0;

  info "Checking installation tool dependencies..."
  while read -r dependency; do
    EXITCODE=0
    hash "${dependency}" 2>/dev/null || EXITCODE=$?
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="${dependency},${NOTFOUND}"
    fi
  done <<EOF
$AGCLOUD
curl
jq
tr
awk
grep
printf
tail
$AKUBECTL
EOF

  if [[ "${PREPARE_CLUSTER}" -eq 1 ]]; then
    if ! hash kpt 2>/dev/null; then
      NOTFOUND="kpt,${NOTFOUND}"
    fi
  fi

  if [[ -n "${NOTFOUND}" ]]; then
    NOTFOUND="$(strip_last_char "${NOTFOUND}")"
    for dep in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "Dependency not found: ${dep}"
    done
    fatal "One or more dependencies were not found. Please install them and retry."
  fi

  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch
  if [[ "$(uname -m)" != "x86_64" ]]; then
    fatal "Installation is only supported on x86_64."
  fi
}

validate_project() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local RESULT; RESULT=""

  info "Checking for ${PROJECT_ID}..."
  RESULT=$(gcloud projects list \
    --filter="project_id=${PROJECT_ID}" \
    --format="value(project_id)" \
    || true)

  if [[ -z "${RESULT}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF
Unable to find project ${PROJECT_ID}. Please verify the spelling and try
again. To see a list of your projects, run:
  gcloud projects list --format='value(project_id)'
EOF
  fi
}

validate_asm_cluster() {
  validate_cluster
  configure_kubectl
  validate_cluster_registration
  validate_asm_installation
  validate_google_identity_provider
}

validate_vm_dependencies() {
  validate_vm_cli_dependencies
  validate_project
  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" \
    --format="value(projectNumber)")"
  validate_asm_cluster
}