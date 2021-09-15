create-mesh_subcommand() {
  ### Preparation ###
  create-mesh_parse_args "$@"
  create-mesh_prepare_environment
  create-mesh_validate_args

  ### Registration ###
  create_mesh
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
  local PROJECT_ID
  local CLUSTER_LOCATION
  local CLUSTER_NAME
  local CTX_CLUSTER
  local GKE_CLUSTER_URI
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  # validate fleet id is valid
  get_project_number "${FLEET_ID}"

  # flatten any kubeconfig files into cluster P/L/C
  # this is GCP-only and will need to be reworked for other platforms
  while read -r KCF; do
    # check a default context exists
    local CONTEXT; CONTEXT="$(kubectl --kubeconfig "${KCF}" config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      fatal "Missing current-context in ${KCF}. Please set a current-context in the KUBECONFIG"
    else
      # use the default context to add to clusterInfo list
      IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT}
EOF
      context_append "clustersInfo" "${PROJECT_ID} ${CLUSTER_LOCATION} ${CLUSTER_NAME}"
    fi
  done < <(context_list "kubeconfigFiles")

  # validate clusters are valid
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    validate_cluster "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
    configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"

    CTX_CLUSTER="$(kubectl config current-context)"
    if ! is_membership_crd_installed; then
      GKE_CLUSTER_URI="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink)')"
      context_append "clusterRegistrations" "${CTX_CLUSTER} ${GKE_CLUSTER_URI}"
    else
      exit_if_cluster_registered_to_another_fleet "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
      warn "Cluster ${CLUSTER_NAME} is already registered with project ${PROJECT_ID}. Skipping."
    fi
    context_append "clusterContexts" "${CTX_CLUSTER}"
  done <<EOF
$(context_list "clustersInfo")
EOF
}

create_mesh() {
  local CTX_CLUSTER GKE_CLUSTER_URI

  # for-loop does not read lines but words, so setting IFS to explicitly split with line breaks
  # Also context_list might return an empty list so we use for-loop to bypass that scenario
  while read -r CTX_CLUSTER GKE_CLUSTER_URI; do
    add_one_to_mesh "${CTX_CLUSTER}" "${GKE_CLUSTER_URI}"
  done < <(context_list "clusterRegistrations")
}

add_one_to_mesh() {
  local CTX_CLUSTER; CTX_CLUSTER="${1}"
  local GKE_CLUSTER_URI; GKE_CLUSTER_URI="${2}"
  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME MEMBERSHIP_NAME
  IFS='_' read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME < <(echo "$CTX_CLUSTER")

  MEMBERSHIP_NAME="$(generate_membership_name "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}")"

  info "Registering the cluster ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME} as ${MEMBERSHIP_NAME}..."

  retry 2 gcloud container hub memberships register "${MEMBERSHIP_NAME}" \
    --project="${PROJECT_ID}" \
    --gke-uri="${GKE_CLUSTER_URI}" \
    --enable-workload-identity
}

install_all_remote_secrets() {
  local CTX_CLUSTER1 CTX_CLUSTER2

  while read -r CTX_CLUSTER1; do
    while read -r CTX_CLUSTER2; do
      if [[ "${CTX_CLUSTER1}" != "${CTX_CLUSTER2}" ]]; then
        install_one_remote_secret "${CTX_CLUSTER1}" "${CTX_CLUSTER2}"
      fi
    done <<EOF
$(context_list "clusterContexts")
EOF
  done <<EOF
$(context_list "clusterContexts")
EOF
}

install_one_remote_secret() {
  local CTX_CLUSTER1; CTX_CLUSTER1="${1}"
  local CTX_CLUSTER2; CTX_CLUSTER2="${2}"
  local SECRET_NAME; SECRET_NAME="$(generate_secret_name "${CTX_CLUSTER1//_/-}")"

  info "Installing remote secret ${SECRET_NAME} on ${CTX_CLUSTER2}..."

  retry 2 istioctl x create-remote-secret \
    --context="${CTX_CLUSTER1}" \
    --name="${SECRET_NAME}" | \
    kubectl apply --context="${CTX_CLUSTER2}" -f -
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
