parse_args() {
  if [[ "${*}" = '' ]]; then
    usage_short >&2
    exit 2
  fi

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

validate_args() {
  ### Option variables ###
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local PLATFORM; PLATFORM="$(context_get-option "PLATFORM")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local CA; CA="$(context_get-option "CA")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY="$(context_get-option "OPTIONAL_OVERLAY")"
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local MANAGED_SERVICE_ACCOUNT; MANAGED_SERVICE_ACCOUNT="$(context_get-option "MANAGED_SERVICE_ACCOUNT")"
  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local CUSTOM_CA; CUSTOM_CA="$(context_get-option "CUSTOM_CA")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CUSTOM_REVISION; CUSTOM_REVISION="$(context_get-option "CUSTOM_REVISION")"
  local WI_ENABLED; WI_ENABLED="$(context_get-option "WI_ENABLED")"
  local CONTEXT; CONTEXT="$(context_get-option "CONTEXT")"
  local KUBECONFIG_SUPPLIED; KUBECONFIG_SUPPLIED="$(context_get-option "KUBECONFIG_SUPPLIED")"

  if [[ -z "${CA}" ]]; then
    CA="mesh_ca"
    context_set-option "CA" "${CA}"
  fi

  if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
    validate_revision_label
  fi

  if is_managed; then
    if [[ "${CA}" == "citadel" ]]; then
      fatal "Citadel is not supported with managed control plane."
    fi

    if [[ "${CA}" == "gcp_cas" ]]; then
      fatal "Google Certificate Authority Service integration is not supported with managed control plane."
    fi

    if [[ "${CUSTOM_CA}" -eq 1 ]]; then
      fatal "Specifying a custom CA with managed control plane is not supported."
    fi

    if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
      fatal "Specifying a revision label with managed control plane is not supported."
    fi

    if [[ -n "${CUSTOM_OVERLAY}" ]]; then
      fatal "Specifying a custom overlay file with managed control plane is not supported."
    fi
  fi

  if [[ -z "${PLATFORM}" ]]; then
    PLATFORM="gcp"
    context_set-option "PLATFORM" "gcp"
  fi

  case "${PLATFORM}" in
      gcp | multicloud);;
      *) fatal "PLATFORM must be one of 'gcp', 'multicloud'";;
  esac

  local MISSING_ARGS=0

  local CLUSTER_DETAIL_SUPPLIED=0
  local CLUSTER_DETAIL_VALID=1
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      CLUSTER_DETAIL_VALID=0
    else
      CLUSTER_DETAIL_SUPPLIED=1 # gke cluster param usage intended
    fi
  done <<EOF
PROJECT_ID
CLUSTER_LOCATION
CLUSTER_NAME
EOF

  # Script will not infer the intent between the 2 use cases in case both values are provided
  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    fatal_with_usage "Incompatible arguments. Kubeconfig cannot be used in conjuntion with [--cluster_location|--cluster_name|--project_id]."
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${CLUSTER_DETAIL_VALID}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "Missing one or more required options for [CLUSTER_LOCATION|CLUSTER_NAME|PROJECT_ID]"
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 0 && "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "At least one of the following is required: 1) --kubeconfig or 2) --cluster_location, --cluster_name, --project_id"
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 && -z "${CONTEXT}" ]]; then
    # set CONTEXT to current-context in the KUBECONFIG
    # or fail-fast if current-context doesn't exist
    CONTEXT="$(kubectl config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      MISSING_ARGS=1
      warn "Missing current-context in the KUBECONFIG. Please provide context with --context flag or set a current-context in the KUBECONFIG"
    else
      context_set-option "CONTEXT" "${CONTEXT}"
    fi
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    info "Reading cluster information for ${CONTEXT}"
    IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT}
EOF
    if is_gcp; then
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
      context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
      context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
    fi
  fi

  if is_gcp; then
    # when no Fleet Id is provided, default to the cluster's project as the Fleet host.
    if [[ -z "${FLEET_ID}" ]]; then
      FLEET_ID="${PROJECT_ID}"
      context_set-option "FLEET_ID" "${FLEET_ID}"
    fi
  else
    # set Project Id to same as Fleet Id.
    # Project Id will be used to enable APIs if applicable.
    if [[ -n "${FLEET_ID}" ]]; then
      PROJECT_ID="${FLEET_ID}"
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
    fi
  fi

  if can_register_cluster && ! has_value "FLEET_ID"; then
    MISSING_ARGS=1
    warn "Missing FLEET_ID to register the cluster."
  fi

  case "${CA}" in
    citadel | mesh_ca | gcp_cas);;
    "")
      MISSING_ARGS=1
      warn "Missing value for CA"
      ;;
    *) fatal "CA must be one of 'citadel', 'mesh_ca', 'gcp_cas'";;
  esac

  if [[ "${CA}" = "gcp_cas" ]]; then
    validate_private_ca
  elif [[ "${CUSTOM_CA}" -eq 1 ]]; then
    validate_citadel
  fi

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
ENABLE_ALL
ENABLE_CLUSTER_ROLES
ENABLE_CLUSTER_LABELS
ENABLE_GCP_APIS
ENABLE_GCP_IAM_ROLES
ENABLE_GCP_COMPONENTS
ENABLE_REGISTRATION
MANAGED
DISABLE_CANONICAL_SERVICE
ONLY_VALIDATE
ONLY_ENABLE
VERBOSE
EOF

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_ROLES}" -eq 1 || \
    "${ENABLE_CLUSTER_LABELS}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 || \
    "${ENABLE_GCP_IAM_ROLES}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 || \
    "${ENABLE_REGISTRATION}" -eq 1  || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
      fatal "The only_validate flag cannot be used with any --enable* flag"
    fi
  elif only_enable; then
    fatal "You must specify at least one --enable* flag with --only_enable"
  fi

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

  local ABS_OVERLAYS; ABS_OVERLAYS=""
  while read -d ',' -r yaml_file; do
    if [[ -f "${yaml_file}" ]]; then
      ABS_OVERLAYS="$(apath -f "${yaml_file}"),${ABS_OVERLAYS}"
    elif [[ -n "${yaml_file}" ]]; then
      fatal "Couldn't find yaml file ${yaml_file}."
    fi
  done <<EOF
${CUSTOM_OVERLAY}
EOF
  CUSTOM_OVERLAY="${ABS_OVERLAYS}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"

  WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"; readonly WORKLOAD_POOL

  validate_hub
}

arg_required() {
  if [[ ! "${2:-}" || "${2:0:1}" = '-' ]]; then
    fatal "Option ${1} requires an argument."
  fi
}
