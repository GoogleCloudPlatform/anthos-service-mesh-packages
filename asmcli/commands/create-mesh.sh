create-mesh_subcommand() {
  ### Preparation ###

  # using kubeconfig globally for create-mesh sub-command
  context_set-option "KUBECONFIG_SUPPLIED" 1

  create-mesh_parse_args "$@"
  create-mesh_prepare_environment
  create-mesh_validate_args

  ### Registration ###
  create-mesh_register
  patch_trust_domain_aliases
  install_all_remote_secrets
}

create-mesh_parse_args() {
  if [[ $# -lt 2 ]]; then
    create-mesh_usage_short
    exit 2
  fi

  case "${1}" in
    -v | --verbose)
      case "${2}" in
        -h | --help) create-mesh_usage; exit;;
      esac
      ;;
    -h | --help)
      case "${2}" in
        -v | --verbose) create-mesh_usage; exit;;
      esac
      ;;
  esac

  local FLEET_ID; FLEET_ID="${1}"
  if [[ "${FLEET_ID}" = -* ]]; then
    fatal "First argument must be the fleet ID."
  fi

  context_set-option "FLEET_ID" "${FLEET_ID}"
  shift 1

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
      --ignore_workload_identity_mismatch | --ignore-workload-identity-mismatch)
        context_set-option "TRUST_FLEET_IDENTITY" 0
        shift 1
        ;;
      *)
        if [ -f "$1" ]; then
          local KCF; KCF="${1}"
          KCF="$(apath -f "${KCF}")" || fatal "Couldn't find file ${KCF}"
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

create-mesh_validate_args() {
  local KCF
  local PROJECT_ID
  local CLUSTER_LOCATION
  local CLUSTER_NAME
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  # validate fleet id is valid
  get_project_number "${FLEET_ID}"

  # generate kubeconfig files for each cluster P/L/C
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    # set KCF to the new kubeconfig
    KCF="$(mktemp)"

    # generate kubeconfig
    info "Fetching/writing GCP credentials to ${KCF}..."
    KUBECONFIG="${KCF}" retry 2 gcloud container clusters get-credentials "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${CLUSTER_LOCATION}"

    # save the kubeconfig to context
    context_append "kubeconfigFiles" "${KCF}"
  done < <(context_list "clustersInfo")

  # required because registration command is different for GCP vs off-GCP clusters
  create-mesh_set_platform

  # validate clusters are valid
  while read -r KCF; do
    context_set-option "KUBECONFIG" "${KCF}"
    context_set-option "CONTEXT" "$(kubectl config current-context)"
    is_cluster_registered
  done <<EOF
$(context_list "kubeconfigFiles")
EOF
}

# Sets the PLATFORM context variable to either {gke|multicloud}
# depending on the kubectl context.
# For a homogeneous mesh, need to be called only once.
# For a hybrid mesh, need to be called for each context change.
create-mesh_set_platform() {
  local FIRST_KCF; FIRST_KCF="$(context_list "kubeconfigFiles" | head -n 1)"
  context_set-option "KUBECONFIG" "${FIRST_KCF}"
  if [[ "$(kubectl config current-context)" =~ "gke_" ]]; then
    context_set-option "PLATFORM" "gcp"
  else
    context_set-option "PLATFORM" "multicloud"
  fi
}

create-mesh_register() {
  while read -r KCF; do
    context_set-option "KUBECONFIG" "${KCF}"
    context_set-option "CONTEXT" "$(kubectl config current-context)"
    if is_gcp; then parse_context; fi
    register_cluster
  done <<EOF
$(context_list "kubeconfigFiles")
EOF
}

parse_context() {
    local PROJECT LOCATION CLUSTER
    IFS="_" read -r _ PROJECT LOCATION CLUSTER <<<"$(context_get-option "CONTEXT")"
    context_set-option "PROJECT_ID" "${PROJECT}"
    context_set-option "CLUSTER_LOCATION" "${LOCATION}"
    context_set-option "CLUSTER_NAME" "${CLUSTER}"
}

install_all_remote_secrets() {
  while read -r KCF1; do
    while read -r KCF2; do
      if [[ "${KCF1}" != "${KCF2}" ]]; then
        install_one_remote_secret "${KCF1}" "${KCF2}"
      fi
    done <<EOF
$(context_list "kubeconfigFiles")
EOF
  done <<EOF
$(context_list "kubeconfigFiles")
EOF
}

install_one_remote_secret() {
  local KCF1; KCF1="${1}"
  local KCF2; KCF2="${2}"
  local CTX1
  local CTX2
  local SECRET_NAME

  context_set-option "KUBECONFIG" "${KCF1}"
  CTX1="$(kubectl config current-context)"

  SECRET_NAME="${CTX1}"
  if [[ "${CTX1}" =~ ^gke_[^_]+_[^_]+_.+ ]]; then
    SECRET_NAME="${SECRET_NAME/#gke-/cn-}"
  fi
  SECRET_NAME="$(generate_secret_name "${SECRET_NAME}")"

  context_set-option "KUBECONFIG" "${KCF2}"
  local CTX2; CTX2="$(kubectl config current-context)"

  info "Installing remote secret ${SECRET_NAME} on ${KCF2}..."

  retry 2 istioctl x create-remote-secret \
    --kubeconfig="${KCF1}" \
    --context="${CTX1}" \
    --name="${SECRET_NAME}" | \
    kubectl apply --kubeconfig="${KCF2}" --context="${CTX2}" -f -
}

# Need to prepare differently under multicluster environment
# validate_cluster and configure_kubectl will be called in validation
# for each cluster
create-mesh_prepare_environment() {
  set_up_local_workspace

  validate_cli_dependencies

  if is_sa; then
    auth_service_account
  fi

  if needs_asm && needs_kpt; then
    download_kpt
  fi
  readonly AKPT

  if needs_asm; then
    if ! necessary_files_exist; then
      download_asm
    fi
    if should_download_kpt_package; then
      download_kpt_package
    fi
    organize_kpt_files
  fi
}

patch_trust_domain_aliases() {
  local PROJECT_ID
  local CLUSTER_LOCATION
  local CLUSTER_NAME
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local TRUST_FLEET_IDENTITY; TRUST_FLEET_IDENTITY="$(context_get-option "TRUST_FLEET_IDENTITY")"
  if [[ "$TRUST_FLEET_IDENTITY" -eq 0 ]]; then
    return
  fi
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    # Off-GCP clusters won't have this info
    if [[ -z "${PROJECT_ID}" || -z "${CLUSTER_LOCATION}" || -z "${CLUSTER_NAME}" ]]; then continue; fi

    configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
    local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
    if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
      info "Check trust domain aliases of cluster gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"
      local REVISION; REVISION="$(retry 2 kubectl -n istio-system get pod -l app=istiod \
        -o jsonpath='{.items[].spec.containers[].env[?(@.name=="REVISION")].value}' 2>/dev/null)"

      if [[ -z "${REVISION}" ]]; then
        warn "$(starline)"
        warn "Couldn't automatically determine the revision for the cluster."
        warn "This is normally benign, but in certain multi-project scenarios cross-project traffic"
        warn "may behave unexpectedly. If this is the case, you may need to re-initialize ASM"
        warn "installations (e.g. by re-running 'asmcli install') to ensure that Fleet workload"
        warn "identity is set up properly."
        warn "$(starline)"
        return
      fi

      local REV_NAME; REV_NAME="istio-${REVISION}"
      if [[ "${REVISION}" = default ]]; then
        REV_NAME="istio"
      fi

      # Patch the configmap of the cluster if it does not include FLEET_ID.svc.id.goog
      if ! has_fleet_alias "${FLEET_ID}" "${REV_NAME}"; then
        info "Patching ${REV_NAME} configmap trustDomainAliases on cluster ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME} with ${FLEET_ID}.svc.id.goog"
        local CONFIGMAP_YAML; CONFIGMAP_YAML="$(retry 2 kubectl -n istio-system get configmap "${REV_NAME}" -o yaml)"
        CONFIGMAP_YAML="$(echo "$CONFIGMAP_YAML" | sed '/^    trustDomainAliases:.*/a \    - '"${FLEET_ID}.svc.id.goog"'')"
        echo "$CONFIGMAP_YAML"| kubectl apply -f - || warn "failed to patch the configmap ${REV_NAME}"
      fi
    fi

  done <<EOF
$(context_list "clustersInfo")
EOF
}

has_fleet_alias() {
  local FLEET_ID; FLEET_ID="${1}"
  local REV_NAME; REV_NAME="${2}"
  local RAW_TRUST_DOMAIN_ALIASES; RAW_TRUST_DOMAIN_ALIASES="$(retry 2 kubectl -n istio-system get configmap "${REV_NAME}" \
    -o jsonpath='{.data.mesh}' | sed -e '1,/trustDomainAliases:/ d')"
  local RAW_TRUST_DOMAIN_ALIAS
  while IFS= read -r RAW_TRUST_DOMAIN_ALIAS; do
    if [[ "${RAW_TRUST_DOMAIN_ALIAS}" != *"- "* ]]; then false; return; fi
    if [[ "${RAW_TRUST_DOMAIN_ALIAS}" == *"- ${FLEET_ID}.svc.id.goog"* ]]; then
      return
    fi
  done < <(printf '%s\n' "$RAW_TRUST_DOMAIN_ALIASES")
  false
}
