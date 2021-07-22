parse_args() {
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY=""
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY=""
  REVISION_LABEL="$(context_get-option "REVISION_LABEL")"
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
      --kc | --kubeconfig)
        arg_required "${@}"
        context_set-option "KUBECONFIG" "${2}"
        context_set-option "KUBECONFIG_SUPPLIED" 1
        shift 2
        ;;
      --ctx | --context)
        arg_required "${@}"
        context_set-option "CONTEXT" "${2}"
        shift 2
        ;;
      -p | --project_id | --project-id)
        arg_required "${@}"
        context_set-option "PROJECT_ID" "${2}"
        shift 2
        ;;
      -m | --mode)
        warn "As of version 1.10 the --mode flag is deprecated and will be ignored."
        shift 2
        ;;
      --fleet_id | --fleet-id)
        arg_required "${@}"
        context_set-option "FLEET_ID" "${2}"
        shift 2
        ;;
      -c | --ca)
        arg_required "${@}"
        context_set-option "CA" "$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --ca_name | --ca-name)
        arg_required "${@}"
        context_set-option "CA_NAME" "${2}"
        shift 2
        ;;
      -o | --option)
        arg_required "${@}"

        if [[ "${2}" == "cni-managed" ]]; then
          context_set-option "USE_MCP_CNI" 1
          shift 2
          continue
        fi

        OPTIONAL_OVERLAY="${2},${OPTIONAL_OVERLAY}"
        context_set-option "OPTIONAL_OVERLAY" "${OPTIONAL_OVERLAY}"
        if [[ "${2}" == "hub-meshca" ]]; then
          context_set-option "USE_HUB_WIP" 1
        fi
        if [[ "${2}" == "vm" ]]; then
          context_set-option "USE_VM" 1
        fi
        shift 2
        ;;
      --co | --custom_overlay | --custom-overlay)
        arg_required "${@}"
        CUSTOM_OVERLAY="${2},${CUSTOM_OVERLAY}"
        context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"
        shift 2
        ;;
      -e | --enable_all | --enable-all)
        context_set-option "ENABLE_ALL" 1
        shift 1
        ;;
      --enable_cluster_roles | --enable-cluster-roles)
        context_set-option "ENABLE_CLUSTER_ROLES" 1
        shift 1
        ;;
      --enable_cluster_labels | --enable-cluster-labels)
        context_set-option "ENABLE_CLUSTER_LABELS" 1
        shift 1
        ;;
      --enable_gcp_apis | --enable-gcp-apis)
        context_set-option "ENABLE_GCP_APIS" 1
        shift 1
        ;;
      --enable_gcp_iam_roles | --enable-gcp-iam-roles)
        context_set-option "ENABLE_GCP_IAM_ROLES" 1
        shift 1
        ;;
      --enable_gcp_components | --enable-gcp-components)
        context_set-option "ENABLE_GCP_COMPONENTS" 1
        shift 1
        ;;
      --enable_registration | --enable-registration)
        context_set-option "ENABLE_REGISTRATION" 1
        shift 1
        ;;
      --enable_namespace_creation | --enable-namespace-creation)
        context_set-option "ENABLE_NAMESPACE_CREATION" 1
        shift 1
        ;;
      --managed)
        context_set-option "MANAGED" 1
        REVISION_LABEL="asm-managed"
        shift 1
        ;;
      --disable_canonical_service | --disable-canonical-service)
        context_set-option "DISABLE_CANONICAL_SERVICE" 1
        shift 1
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
        warn "In version 1.11 the --only_validate flag will be deprecated and ignored."
        warn "Please use \"asmcli valdiate\" instead."
        context_set-option "ONLY_VALIDATE" 1
        shift 1
        ;;
      --only_enable | --only-enable)
        context_set-option "ONLY_ENABLE" 1
        shift 1
        ;;
      --ca_cert | --ca-cert)
        arg_required "${@}"
        context_set-option "CA_CERT" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --ca_key | --ca-key)
        arg_required "${@}"
        context_set-option "CA_KEY" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --root_cert | --root-cert)
        arg_required "${@}"
        context_set-option "CA_ROOT" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --cert_chain | --cert-chain)
        arg_required "${@}"
        context_set-option "CA_CHAIN" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      -r | --revision_name | --revision-name)
        arg_required "${@}"
        context_set-option "CUSTOM_REVISION" 1
        REVISION_LABEL="${2}"
        shift 2
        ;;
      --platform)
        arg_required "${@}"
        context_set-option "PLATFORM" "$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
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
      *)
        fatal_with_usage "Unknown option ${1}"
        ;;
    esac
  done
  RAW_YAML="${REVISION_LABEL}-manifest-raw.yaml"; readonly RAW_YAML;
  EXPANDED_YAML="${REVISION_LABEL}-manifest-expanded.yaml"; readonly EXPANDED_YAML;
  readonly REVISION_LABEL

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

parse_create_mesh_args() {
  if [[ $# -lt 2 ]]; then
    create-mesh_usage_short
    exit 2
  fi

  local FLEET_ID; FLEET_ID="${1}"
  context_set-option "FLEET_ID" "${FLEET_ID}"
  shift 1

  while [[ $# != 0 ]]; do
    case "${1}" in
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
      *)
        if [ -f "$1" ]; then
          local KCF; KCF="${1}"
          context_append "kubeconfigFiles" "${KCF}"
        else
          local CLUSTER; CLUSTER="${1}"
          context_append "clustersInfo" "${CLUSTER//\// }"
        fi
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
      create-mesh_usage
    else
      create-mesh_usage_short
    fi
    exit
  fi
}

x_parse_install_args() {
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
      --kc | --kubeconfig)
        arg_required "${@}"
        context_set-option "KUBECONFIG" "${2}"
        context_set-option "KUBECONFIG_SUPPLIED" 1
        shift 2
        ;;
      --ctx | --context)
        arg_required "${@}"
        context_set-option "CONTEXT" "${2}"
        shift 2
        ;;
      -p | --project_id | --project-id)
        arg_required "${@}"
        context_set-option "PROJECT_ID" "${2}"
        shift 2
        ;;
      --fleet_id | --fleet-id)
        arg_required "${@}"
        context_set-option "FLEET_ID" "${2}"
        shift 2
        ;;
      -e | --enable_all | --enable-all)
        context_set-option "ENABLE_ALL" 1
        shift 1
        ;;
      --enable_cluster_labels | --enable-cluster-labels)
        context_set-option "ENABLE_CLUSTER_LABELS" 1
        shift 1
        ;;
      --enable_gcp_apis | --enable-gcp-apis)
        context_set-option "ENABLE_GCP_APIS" 1
        shift 1
        ;;
      --enable_gcp_iam_roles | --enable-gcp-iam-roles)
        context_set-option "ENABLE_GCP_IAM_ROLES" 1
        shift 1
        ;;
      --enable_gcp_components | --enable-gcp-components)
        context_set-option "ENABLE_GCP_COMPONENTS" 1
        shift 1
        ;;
      --enable_registration | --enable-registration)
        context_set-option "ENABLE_REGISTRATION" 1
        shift 1
        ;;
      --enable_namespace_creation | --enable-namespace-creation)
        context_set-option "ENABLE_NAMESPACE_CREATION" 1
        shift 1
        ;;
      --disable_canonical_service | --disable-canonical-service)
        context_set-option "DISABLE_CANONICAL_SERVICE" 1
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
      *)
        fatal_with_usage "Unknown option ${1}"
        ;;
    esac
  done
  RAW_YAML="${REVISION_LABEL}-manifest-raw.yaml"; readonly RAW_YAML;
  EXPANDED_YAML="${REVISION_LABEL}-manifest-expanded.yaml"; readonly EXPANDED_YAML;
  readonly REVISION_LABEL

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
