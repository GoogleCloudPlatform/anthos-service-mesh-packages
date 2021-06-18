add-to-mesh_subcommand() {
  ### Preparation ###
  parse_cluster_args "$@"
  validate_cluster_args
  add_all_to_mesh
}

parse_cluster_args() {
  if [[ $# != 0 ]]; then
    local FLEET_ID; FLEET_ID="${1}"
    context_set-option "FLEET_ID" "${FLEET_ID}"
    shift 1
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
  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    context_set-option "PROJECT_ID" "${PROJECT_ID}"
    context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
    context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"

    validate_cluster
    configure_kubectl

    if ! is_membership_crd_installed; then
      GKE_CLUSTER_URI="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink)')"
      context_append-cluster-registrations "${PROJECT_ID} ${CLUSTER_LOCATION} ${CLUSTER_NAME} ${GKE_CLUSTER_URI}"
    else
      exit_if_cluster_registered_to_another_fleet
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
  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI
  local MEMBERSHIP_NAME; MEMBERSHIP_NAME=""
  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI; do
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
  done <<EOF
$(context_list "clusterRegistrations")
EOF
}
