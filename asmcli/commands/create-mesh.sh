create-mesh_subcommand() {
  ### Preparation ###
  parse_create_mesh_args "$@"
  prepare_create_mesh_environment
  validate_create_mesh_args

  ### Registration ###
  create_mesh
  install_all_remote_secrets
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
