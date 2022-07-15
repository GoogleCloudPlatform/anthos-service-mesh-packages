vm_subcommand() {
  if [[ "${*}" = '' ]]; then
    vm_usage >&2
    exit 2
  fi

  init_vm
  parse_subcommand_for_vm "$@"
}

init_vm() {
  ASM_REVISIONS=""

  EXPANSION_GATEWAY_NAME="istio-eastwestgateway"; readonly EXPANSION_GATEWAY_NAME
  ASM_REVISION_LABEL_KEY="istio.io/rev"; readonly ASM_REVISION_LABEL_KEY
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
      error "Unknown subcommand ${1}"
      vm_usage >&2
      exit 2
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

  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
    info "Successfully validated all prerequistes from this shell."
    exit 0
  fi

  local INSTALL_EXPANSION_GATEWAY; INSTALL_EXPANSION_GATEWAY="$(context_get-option "INSTALL_EXPANSION_GATEWAY")"
  local INSTALL_IDENTITY_PROVIDER; INSTALL_IDENTITY_PROVIDER="$(context_get-option "INSTALL_IDENTITY_PROVIDER")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  if [[ "${INSTALL_EXPANSION_GATEWAY}" -eq 1 ]] || [[ "${INSTALL_IDENTITY_PROVIDER}" -eq 1 ]]; then
    set_up_local_workspace
    configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
    if needs_kpt; then
      download_kpt
    fi
    readonly AKPT
    download_asm
    if [[ "${INSTALL_IDENTITY_PROVIDER}" -eq 1 ]]; then
      install_google_identity_provider
    fi
    if [[ "${INSTALL_EXPANSION_GATEWAY}" -eq 1 ]]; then
      install_expansion_gateway
      expose_istiod_vm
    fi
  fi

  enable_service_mesh_feature
  success_message_prepare_cluster
  return 0
}

validate_vm_dependencies() {
  validate_cli_dependencies

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local FLEET_ID; FLEET_ID="${PROJECT_ID}"
  context_set-option "FLEET_ID" "${FLEET_ID}"
  get_project_number "${FLEET_ID}"

  validate_asm_cluster
}

validate_asm_cluster() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  validate_cluster "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
  configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"

  exit_if_cluster_unregistered

  validate_asm_installation
  validate_google_identity_provider
}

parse_vm_args() {
  if [[ "${*}" = '' ]]; then
    vm_usage >&2
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
        error "Unknown option ${1}"
        vm_usage >&2
        exit 2
        ;;
    esac
  done

  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  if [[ "${PRINT_HELP}" -eq 1 ]]; then
    vm_usage
    exit
  fi
}

vm_usage() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} experimental vm [SUBCOMMAND] [OPTION]...

Set up and prepare Anthos Service Mesh to add VM workloads.

SUBCOMMANDS:
  prepare-cluster                     Prepares the specified cluster to allow
                                      external VM workloads.

OPTIONS:
  -l|--cluster_location  <LOCATION>   The GCP location of the target cluster.
  -n|--cluster_name      <NAME>       The name of the target cluster.
  -p|--project_id        <ID>         The GCP project ID.
  -s|--service_account   <ACCOUNT>    The name of a service account used to
                                      install ASM. If not specified, the gcloud
                                      user currently configured will be used.
  -k|--key_file          <FILE PATH>  The key file for a service account. This
                                      option can be omitted if not using a
                                      service account.

FLAGS:
  -v|--verbose                        Print commands before and after execution.
     --dry_run                        Print commands, but don't execute them.
     --only_validate                  Run validation, but don't install.
  -h|--help                           Show this message and exit.
EOF
}

validate_vm_args() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
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

validate_asm_installation() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"

  info "Checking for istio-system namespace..."
  if [ "$(retry 2 kubectl get ns | grep -c istio-system || true)" -eq 0 ]; then
    fatal "istio-system namespace cannot be found in the cluster. Please install Anthos Service Mesh and retry."
  fi

  info "Verifying Anthos Service Mesh installation..."
  local ISTIOD_NAMES
  ISTIOD_NAMES=$(retry 2 kubectl -n istio-system get deploy -lapp=istiod \
    --no-headers -o custom-columns=":metadata.name")
  if [[ -n "${ISTIOD_NAMES}" ]]; then
    for istiod in ${ISTIOD_NAMES}; do
      local CURR_REVISION
      CURR_REVISION="$(retry 2 kubectl get deployment "${istiod}" \
        -n istio-system -ojson | jq -r \
        '.metadata.labels["'"${ASM_REVISION_LABEL_KEY}"'"]')"
      ASM_REVISIONS="${ASM_REVISIONS} ${CURR_REVISION}"
    done
    readonly ASM_REVISIONS
    local EXPANSION_GATEWAY
    EXPANSION_GATEWAY=$(retry 2 kubectl -n istio-system get deploy \
      "${EXPANSION_GATEWAY_NAME}" --no-headers \
      -o custom-columns=":metadata.name" --ignore-not-found=true)
    if [[ -z "${EXPANSION_GATEWAY}" ]]; then
      if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
        { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
${EXPANSION_GATEWAY_NAME} is not found in the cluster.
Please install Anthos Service Mesh with VM support or run the current script
without the --only_validate flag.
EOF
      else
        context_set-option "INSTALL_EXPANSION_GATEWAY" 1
      fi
    fi
  fi
}

validate_google_identity_provider() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"

  info "Verifying identity providers in the cluster..."
  if ! is_google_identity_provider_installed; then
    if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
      { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
GCE identity provider is not found in the cluster. Please install Anthos Service
Mesh with VM support to allow the script to register the google identity
provider in your cluster or run the current script without the --only_validate
flag.
EOF
    else
      context_set-option "INSTALL_IDENTITY_PROVIDER" 1
    fi
  fi
}

is_google_identity_provider_installed() {
  if ! is_idp_crd_installed; then
    false
    return
  fi

  if ! retry 2 kubectl get identityproviders.security.cloud.google.com -ojsonpath="{..metadata.name}" \
    | grep -w -q google ; then
    false
  fi
}

is_idp_crd_installed() {
  if [[ "$(retry 2 kubectl get crd identityproviders.security.cloud.google.com -ojsonpath="{..metadata.name}" \
    | grep -w -c identityproviders || true)" -eq 0 ]]; then
    false
  fi
}

install_google_identity_provider() {
  info "Registering GCE Identity Provider in the cluster..."
  retry 3 kubectl apply -f asm/identity-provider/identityprovider-crd.yaml
  retry 3 kubectl apply -f asm/identity-provider/googleidp.yaml
}

install_expansion_gateway() {
  if [[ -n "${_CI_ASM_IMAGE_LOCATION}" ]]; then
    kpt cfg set asm anthos.servicemesh.hub "${_CI_ASM_IMAGE_LOCATION}"
  fi
  if [[ -n "${_CI_ASM_IMAGE_TAG}" ]]; then
    kpt cfg set asm anthos.servicemesh.tag "${_CI_ASM_IMAGE_TAG}"
  fi

  local PARAMS; PARAMS="-f ${EXPANSION_GATEWAY_FILE}"

  if [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    PARAMS="${PARAMS} --set revision=${REVISION_LABEL}"
  fi

  PARAMS="${PARAMS} --skip-confirmation"

  info "Installing the expansion gateway..."
  # shellcheck disable=SC2086
  retry 5 istioctl install $PARAMS

  # Prevent the stderr buffer from ^ messing up the terminal output below
  sleep 1
  info "...done!"
}

expose_istiod_vm() {
  info "Exposing the control plane for VM workloads..."
  retry 3 kubectl apply -f "${EXPOSE_ISTIOD_DEFAULT_SERVICE}"

  for rev in ${ASM_REVISIONS}; do
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod-${rev}.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod-${rev}.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs-${rev}"

    retry 3 kubectl apply -f "${EXPOSE_ISTIOD_REVISION_SERVICE}"
  done
}

success_message_prepare_cluster() {
  info "
*****************************
The cluster is ready for adding VM workloads.
Please follow the Anthos Service Mesh for GCE VM user guide to add GCE VMs to
your mesh.
*****************************
"
}
