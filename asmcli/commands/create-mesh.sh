create-mesh_subcommand() {
  ### Preparation ###

  # using kubeconfig globally for create-mesh sub-command
  context_set-option "KUBECONFIG_SUPPLIED" 1
  # setting same behavior for all environments
  context_set-option "PLATFORM" "multicloud"

  create-mesh_parse_args "$@"
  create-mesh_prepare_environment
  create-mesh_validate_args

  ### Registration ###
  create_mesh_register
  patch_trust_domain_aliases
  install_all_remote_secrets
}

create-mesh_parse_args() {
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
      --ignore_workload_identity_mismatch | --ignore-workload-identity-mismatch)
        context_set-option "TRUST_FLEET_IDENTITY" 0
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

create-mesh_validate_args() {
  local KCF
  local CONTEXT_PREFIX
  local PROJECT_ID
  local CLUSTER_LOCATION
  local CLUSTER_NAME
  local CTX_CLUSTER
  local GKE_CLUSTER_URI
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
  done <<EOF
$(context_list "clustersInfo")
EOF

  # validate clusters are valid
  while read -r KCF; do
    context_set-option "KUBECONFIG" "${KCF}"
    context_set-option "CONTEXT" "$(kubectl config current-context)"
    is_cluster_registered
  done <<EOF
$(context_list "kubeconfigFiles")
EOF
}

create-mesh_register() {
  while read -r KCF; do
    context_set-option "KUBECONFIG" "${KCF}"
    context_set-option "CONTEXT" "$(kubectl config current-context)"
    is_cluster_registered
    if ! is_membership_crd_installed; then
      register_cluster
    fi
  done <<EOF
$(context_list "kubeconfigFiles")
EOF
}

install_all_remote_secrets() {
  while read -r KCF1; do
    while read -r KCF2; do
      if [[ "${KCF1}" != "${KCF2}" ]]; then
        install_one_remote_secret "${KCF1}" "${KCF2}"
      fi
    done <<EOF
$(m1context_list "kubeconfigFiles")
EOF
  done <<EOF
$(m1context_list "kubeconfigFiles")
EOF
}

install_one_remote_secret() {
  local KCF1; KCF1="${1}"
  local KCF2; KCF2="${2}"
  local SECRET_NAME; SECRET_NAME="$(generate_secret_name "${KCF1//_/-}")"

  info "Installing remote secret ${SECRET_NAME} on ${KCF2}..."

  retry 2 istioctl x create-remote-secret \
    --kubeconfig="${KCF1}" \
    --name="${SECRET_NAME}" | \
    kubectl apply --kubeconfig="${KCF2}" -f -
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
    configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
    local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
    if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
      info "Check trust domain aliases of cluster gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}"
      local REVISION; REVISION="$(retry 2 kubectl -n istio-system get pod -l istio=istiod \
        -o jsonpath='{.items[].spec.containers[].env[?(@.name=="REVISION")].value}')"

      # Patch the configmap of the cluster if it does not include FLEET_ID.svc.id.goog
      if ! has_fleet_alias "${FLEET_ID}" "${REVISION}"; then
        info "Patching istio-${REVISION} configmap trustDomainAliases on cluster ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME} with ${FLEET_ID}.svc.id.goog"
        local CONFIGMAP_YAML; CONFIGMAP_YAML="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" -o yaml)"
        CONFIGMAP_YAML="$(echo "$CONFIGMAP_YAML" | sed '/^    trustDomainAliases:.*/a \    - '"${FLEET_ID}.svc.id.goog"'')"
        echo "$CONFIGMAP_YAML"| kubectl apply -f - || warn "failed to patch the configmap istio-${REVISION}"
      fi
    fi

  done <<EOF
$(context_list "clustersInfo")
EOF
}

has_fleet_alias() {
  local FLEET_ID; FLEET_ID="${1}"
  local REVISION; REVISION="${2}"
  local RAW_TRUST_DOMAIN_ALIASES; RAW_TRUST_DOMAIN_ALIASES="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" \
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
