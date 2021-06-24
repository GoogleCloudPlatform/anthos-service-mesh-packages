add-to-mesh_subcommand() {
  ### Preparation ###
  parse_cluster_args "$@"
  prepare_add_to_mesh_environment
  validate_cluster_args
  add_all_to_mesh
  install_all_secrets
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
    local CLUSTER; CLUSTER="${1}"
    context_append "clustersInfo" "${CLUSTER//\// }"
    shift 1
  done
}

validate_cluster_args() {
  # validate fleet id is valid
  get_project_number

  # validate clusters are valid
  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME CTX_CLUSTER GKE_CLUSTER_URI
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    context_set-option "PROJECT_ID" "${PROJECT_ID}"
    context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
    context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"

    validate_cluster
    configure_kubectl

    if ! is_membership_crd_installed; then
      CTX_CLUSTER="$(kubectl config current-context)"
      GKE_CLUSTER_URI="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink)')"
      context_append "clusterRegistrations" "${CTX_CLUSTER} ${GKE_CLUSTER_URI}"
    else
      exit_if_cluster_registered_to_another_fleet
      info "Cluster ${CLUSTER_NAME} is already registered with project ${PROJECT_ID}. Skipping."
    fi
  done <<EOF
$(context_list "clustersInfo")
EOF
}

exit_if_cluster_registered_to_another_fleet() {
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

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
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME CTX_CLUSTER GKE_CLUSTER_URI GCE_NETWORK_NAME
  local MEMBERSHIP_NAME

  IFS=$'\n'
  for line in $(context_list "clusterRegistrations"); do
    read -r A B C D < <(echo $line)
    echo "$A $B $C $D"
  done


  while read -r CTX_CLUSTER GKE_CLUSTER_URI; do
    IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CTX_CLUSTER}
EOF
    if [[ -n "${PROJECT_ID}" && -n "${CLUSTER_LOCATION}" && -n "${CLUSTER_NAME}" && -n "${GKE_CLUSTER_URI}" ]]; then
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
      context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
      context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
      MEMBERSHIP_NAME="$(generate_membership_name)"

      info "Registering the cluster ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME} as ${MEMBERSHIP_NAME}..."

      local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
      retry 2 run_command gcloud beta container hub memberships register "${MEMBERSHIP_NAME}" \
        --project="${PROJECT_ID}" \
        --gke-uri="${GKE_CLUSTER_URI}" \
        --enable-workload-identity
    else
      { read -r -d '' MSG; warn "${MSG}"; } <<EOF || true
Unable to register the cluster due to unexpected cluster information:
  Project ID: ${PROJECT_ID}
  Cluster Location: ${CLUSTER_LOCATION}
  Cluster Name: ${CLUSTER_NAME}
EOF
    fi
  done <<EOF
$(context_list "clusterRegistrations")
EOF
}

install_all_secrets() {
  local CTX_CLUSTER1 CTX_CLUSTER2

  while read -r CTX_CLUSTER1 _; do
    while read -r CTX_CLUSTER2 _; do
      if [[ "${CTX_CLUSTER1}" != "${CTX_CLUSTER2}" ]]; then
        install_remote_secret "${CTX_CLUSTER1}" "${CTX_CLUSTER2}"
      fi
    done <<EOF
$(context_list "clusterRegistrations")
EOF
  done <<EOF
$(context_list "clusterRegistrations")
EOF
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

install_remote_secret() {
  local CTX_CLUSTER1; CTX_CLUSTER1="${1}"
  local CTX_CLUSTER2; CTX_CLUSTER2="${2}"
  local SECRET_NAME; SECRET_NAME="${CTX_CLUSTER1//_/-}"

  info "Installing remote secret ${SECRET_NAME} on ${CTX_CLUSTER2}..."

  run_command istioctl x create-remote-secret \
    --context="${CTX_CLUSTER1}" \
    --name="${SECRET_NAME}" | \
    kubectl apply --context="${CTX_CLUSTER2}" -f -
}

