create-mesh_subcommand() {
  ### Preparation ###
  parse_cluster_args "$@"
  prepare_add_to_mesh_environment
  validate_cluster_args

  ### Registration ###
  add_all_to_mesh
  install_all_remote_secrets
}

parse_cluster_args() {
  if [[ $# != 0 ]]; then
    local FLEET_ID; FLEET_ID="${1}"
    context_set-option "FLEET_ID" "${FLEET_ID}"
    shift 1
  fi

  if [[ "${*}" = '' ]]; then
    usage_short >&2
    exit 2
  fi

  while [[ $# != 0 ]]; do
    if [ -e "$1" ]; then
      local KCF; KCF="${1}"
      context_append "kubeconfigFiles" "${KCF}"
    else
      local CLUSTER; CLUSTER="${1}"
      context_append "clustersInfo" "${CLUSTER//\// }"
    fi
    shift 1
  done
}

validate_cluster_args() {
  local KCF
  local PROJECT_ID
  local CLUSTER_LOCATION
  local CLUSTER_NAME
  local CTX_CLUSTER
  local GKE_CLUSTER_URI

  # validate fleet id is valid
  get_project_number

  # flatten any kubeconfig files into cluster P/L/C
  while read -r KCF; do
    # check a default context exists
    CONTEXT="$(kubectl --kubeconfig "${KCF}" config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      fatal "Missing current-context in ${KCF}. Please set a current-context in the KUBECONFIG"
    else
      # use the default context to add to clusterInfo list
      IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT}
EOF
      context_append "clustersInfo" "${PROJECT_ID} ${CLUSTER_LOCATION} ${CLUSTER_NAME}"
    fi
  done <<EOF
$(context_list "kubeconfigFiles")
EOF

  # validate clusters are valid
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    context_set-option "PROJECT_ID" "${PROJECT_ID}"
    context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
    context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"

    validate_cluster
    configure_kubectl

    CTX_CLUSTER="$(kubectl config current-context)"
    if ! is_membership_crd_installed; then
      GKE_CLUSTER_URI="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink)')"
      context_append "clusterRegistrations" "${CTX_CLUSTER} ${GKE_CLUSTER_URI}"
    else
      exit_if_cluster_registered_to_another_fleet
      warn "Cluster ${CLUSTER_NAME} is already registered with project ${PROJECT_ID}. Skipping."
    fi
    context_append "clusterContexts" "${CTX_CLUSTER}"
  done <<EOF
$(context_list "clustersInfo")
EOF
}

exit_if_cluster_registered_to_another_fleet() {
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  local WANT
  WANT="//container.googleapis.com/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
  local LIST
  LIST="$(gcloud container hub memberships list --project "${FLEET_ID}" \
    --format=json | grep "${WANT}")"
  if [[ -z "${LIST}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cluster is already registered but not in the project ${FLEET_ID}.
EOF
  fi
}

add_all_to_mesh() {
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

  context_set-option "PROJECT_ID" "${PROJECT_ID}"
  context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
  context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
  MEMBERSHIP_NAME="$(generate_membership_name)"

  info "Registering the cluster ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME} as ${MEMBERSHIP_NAME}..."

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  retry 2 gcloud beta container hub memberships register "${MEMBERSHIP_NAME}" \
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
prepare_add_to_mesh_environment() {
  set_up_local_workspace

  validate_cli_dependencies

  if is_sa; then
    auth_service_account
  fi

  if needs_asm; then
    if ! necessary_files_exist; then
      download_asm
    fi
    organize_kpt_files
  fi
}

generate_secret_name() {
  local SECRET_NAME; SECRET_NAME="${1}"

  if [[ "${#SECRET_NAME}" -gt "${KUBE_TAG_MAX_LEN}" ]]; then
    local DIGEST
    DIGEST="$(echo "${SECRET_NAME}" | sha256sum | head -c20 || true)"
    SECRET_NAME="${SECRET_NAME:0:42}-${DIGEST}"
  fi

  echo "${SECRET_NAME}"
}
