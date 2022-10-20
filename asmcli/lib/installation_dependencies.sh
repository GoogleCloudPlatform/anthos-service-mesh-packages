required_iam_roles_mcp_sa() {
  cat <<EOF
roles/serviceusage.serviceUsageConsumer
roles/container.admin
roles/monitoring.metricWriter
roles/logging.logWriter
EOF
}

# [START required_iam_roles]
required_iam_roles() {
  # meshconfig.admin - required for init, stackdriver, UI elements, etc.
  # servicemanagement.admin/serviceusage.serviceUsageAdmin - enables APIs
  local CA; CA="$(context_get-option "CA")"
  if is_gcp && { can_modify_gcp_components || \
     can_modify_cluster_labels || \
     can_modify_cluster_roles; }; then
    echo roles/container.admin
  fi
  if can_modify_gcp_components; then
    echo roles/meshconfig.admin
  fi
  if can_modify_gcp_apis; then
    echo roles/servicemanagement.admin
    echo roles/serviceusage.serviceUsageAdmin
  fi
  if can_modify_gcp_iam_roles; then
    echo roles/resourcemanager.projectIamAdmin
  fi
  if is_sa; then
    echo roles/iam.serviceAccountAdmin
  fi
  if can_register_cluster; then
    echo roles/gkehub.admin
  fi
  if [[ "${CA}" = "gcp_cas" ]]; then
    echo roles/privateca.admin
  fi
  if [[ "${_CI_I_AM_A_TEST_ROBOT}" -eq 1 ]]; then
    echo roles/compute.admin
    echo roles/iam.serviceAccountKeyAdmin
  fi
}
# [END required_iam_roles]

# Required IAM roles for GKE Hub registratinon are
# defined in https://cloud.google.com/anthos/fleet-management/docs/before-you-begin#grant_iam_roles
required_iam_roles_registration() {
  if is_gcp; then
    echo roles/container.admin
  else
    echo roles/iam.serviceAccountAdmin
    echo roles/iam.serviceAccountKeyAdmin
    echo roles/resourcemanager.projectIamAdmin
  fi
  echo roles/gkehub.admin
}

# [START required_apis]
required_apis() {
  local CA; CA="$(context_get-option "CA")"
    cat << EOF
mesh.googleapis.com
EOF
  case "${CA}" in
   gcp_cas)
     echo privateca.googleapis.com
     ;;
   managed_cas)
     echo workloadcertificate.googleapis.com
     ;;
    *);;
  esac

  if [[ "${_CI_I_AM_A_TEST_ROBOT}" -eq 1 ]]; then
    echo compute.googleapis.com
  fi
}
# [END required_apis]

required_fleet_apis() {
  local CA; CA="$(context_get-option "CA")"
  echo meshconfig.googleapis.com
  case "${CA}" in
   mesh_ca)
     echo meshca.googleapis.com
     ;;
   gcp_cas)
     echo privateca.googleapis.com
     ;;
   managed_cas)
     echo workloadcertificate.googleapis.com
     ;;
    *);;
  esac
}

bind_user_to_cluster_admin(){
  info "Querying for core/account..."
  local GCLOUD_USER; GCLOUD_USER="$(gcloud config get-value core/account)"
  info "Binding ${GCLOUD_USER} to cluster admin role..."
  local PREFIX; PREFIX="$(echo "${GCLOUD_USER}" | cut -f 1 -d @)"
  local YAML; YAML="$(retry 5 kubectl create \
    clusterrolebinding "${PREFIX}-cluster-admin-binding" \
    --clusterrole=cluster-admin \
    --user="${GCLOUD_USER}" \
    --dry-run=client -o yaml)"
  retry 3 kubectl apply -f - <<EOF
${YAML}
EOF
}

local_iam_user() {
  if [[ -n "${GCLOUD_USER_OR_SA}" ]]; then
    echo "${GCLOUD_USER_OR_SA}"
    return
  fi

  info "Getting account information..."
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local ACCOUNT_NAME
  ACCOUNT_NAME="$(retry 3 gcloud auth list \
    --project="${PROJECT_ID}" \
    --filter="status:ACTIVE" \
    --format="value(account)")"
  if [[ -z "${ACCOUNT_NAME}" ]]; then
    fatal "Failed to get account name from gcloud. Please authorize and re-try installation."
  fi

  local ACCOUNT_TYPE
  ACCOUNT_TYPE="user"
  if is_sa || [[ "${ACCOUNT_NAME}" = *.gserviceaccount.com ]]; then
    ACCOUNT_TYPE="serviceAccount"
  fi

  if is_sa_impersonation; then
    ACCOUNT_NAME="$(gcloud config get-value auth/impersonate_service_account)"
    ACCOUNT_TYPE="serviceAccount"
    warn "Service account impersonation currently configured to impersonate '${ACCOUNT_NAME}'."
  fi

  GCLOUD_USER_OR_SA="${ACCOUNT_TYPE}:${ACCOUNT_NAME}"
  readonly GCLOUD_USER_OR_SA
  echo "${GCLOUD_USER_OR_SA}"
}

bind_user_to_iam_policy(){
  local ROLES; ROLES="${1}"
  local GCLOUD_MEMBER; GCLOUD_MEMBER="${2}"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Binding ${GCLOUD_MEMBER} to required IAM roles..."
  while read -r role; do
  retry 3 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member "${GCLOUD_MEMBER}" \
    --role="${role}" --condition=None >/dev/null
  done <<EOF
${ROLES}
EOF
}

enable_gcloud_apis(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  info "Enabling required APIs..."
  # shellcheck disable=SC2046
  retry 3 gcloud services enable --project="${PROJECT_ID}" $(required_apis | tr '\n' ' ')

  local CA; CA="$(context_get-option "CA")"
  if [[ "${CA}" = "managed_cas" ]]; then
    fail_if_not_experimental
    x_enable_workload_certificate_api "gkehub.googleapis.com" "workloadcertificate.googleapis.com"
  fi

  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    local REQUIRED_FLEET_APIS; REQUIRED_FLEET_APIS="$(required_fleet_apis | tr '\n' ' ')"
    if [[ -n "${REQUIRED_FLEET_APIS// }" ]]; then
      # shellcheck disable=SC2086
      retry 3 gcloud services enable --project="${FLEET_ID}" ${REQUIRED_FLEET_APIS}
    fi
  fi
}

#######
# valid_pool_query takes an integer argument: the minimum vCPU requirement.
# It outputs to stdout a query for `gcloud container node-pools list`
#######
valid_pool_query() {
  cat <<EOF | tr '\n' ' '
    config.machineType.split(sep="-").slice(-1:) >= $1
EOF
}

get_istio_deployment_count(){
  local OUTPUT
  OUTPUT="$(retry 3 kubectl get deployment \
    -n istio-system \
    --ignore-not-found=true)"
  grep -c istiod <<EOF || true
$OUTPUT
EOF
}

# For GCP: project number corresponds to the (optional) ASM Fleet project or the (default) cluster's project.
# For non-GCP: project number corresponds to the (required) ASM Fleet project.
get_project_number() {
  local FLEET_ID; FLEET_ID="${1}"
  local RESULT; RESULT=""

  info "Checking for project ${FLEET_ID}..."

  PROJECT_NUMBER="$(gcloud projects describe "${FLEET_ID}" --format="value(projectNumber)")"; readonly PROJECT_NUMBER

  if [[ -z "${PROJECT_NUMBER}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Unable to find project ${FLEET_ID}. Please verify the spelling and try
again. To see a list of your projects, run:
  gcloud projects list --format='value(project_id)'
EOF
  fi
}

list_valid_pools() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  gcloud container node-pools list \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    --cluster "${CLUSTER_NAME}" \
    --filter "$(valid_pool_query "${1}")"\
    --format=json
}

get_enabled_apis() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local OUTPUT
  OUTPUT="$(retry 3 gcloud services list \
    --enabled \
    --format='get(config.name)' \
    --project="${PROJECT_ID}")"
  echo "${OUTPUT}" | tr '\n' ','
}

mesh_id_label() {
  echo "mesh_id=proj-${PROJECT_NUMBER}"
}

get_cluster_labels() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  # temp workaround for attached clusters again
  if [[ -z "${CLUSTER_LOCATION}" ]]; then return 0; fi

  local LABELS
  if ! is_gcp; then
    local MEMBERSHIP_NAME; MEMBERSHIP_NAME="$(generate_membership_name)"
    info "Reading labels for ${MEMBERSHIP_NAME}..."
    LABELS="$(retry 2 gcloud container hub memberships describe "${MEMBERSHIP_NAME}" \
      --project="${PROJECT_ID}" \
      --format='value(labels)[delimiter=","]')";
  else
    info "Reading labels for ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
    LABELS="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(resourceLabels)[delimiter=","]')";
  fi
  echo "${LABELS}"
}

sanitize_label() {
  local LABEL; LABEL="${1}"

  LABEL="${LABEL//_/-}"
  LABEL="${LABEL//\./-}"
  LABEL="${LABEL//@/-}"
  LABEL="${LABEL//:/-}"

  echo "${LABEL}"
}

generate_membership_name() {
  local MEMBERSHIP_NAME; MEMBERSHIP_NAME="$(context_get-option "HUB_MEMBERSHIP_ID")"
  if [[ -n "${MEMBERSHIP_NAME}" ]]; then echo "${MEMBERSHIP_NAME}"; return; fi

  if is_gcp; then
    local PROJECT_ID; PROJECT_ID="${1}"
    local CLUSTER_LOCATION; CLUSTER_LOCATION="${2}"
    local CLUSTER_NAME; CLUSTER_NAME="${3}"

    MEMBERSHIP_NAME="${CLUSTER_NAME}"
    if [[ "$(retry 2 gcloud container hub memberships list --format='value(name)' \
    --project "${PROJECT_ID}" | grep -c "^${MEMBERSHIP_NAME}$" || true)" -ne 0 ]]; then
      MEMBERSHIP_NAME="${CLUSTER_NAME}-${PROJECT_ID}-${CLUSTER_LOCATION}"
    fi
    if [[ "${#MEMBERSHIP_NAME}" -gt "${KUBE_TAG_MAX_LEN}" ]] || [[ "$(retry 2 gcloud container hub \
    memberships list --format='value(name)' --project "${PROJECT_ID}" | grep -c \
    "^${MEMBERSHIP_NAME}$" || true)" -ne 0 ]]; then
      local RAND
      RAND="$(tr -dc "a-z0-9" </dev/urandom | head -c8 || true)"
      MEMBERSHIP_NAME="${CLUSTER_NAME:0:54}-${RAND}"
    fi
  else
    MEMBERSHIP_NAME="$(date +%s%N)"
  fi
  context_set-option "HUB_MEMBERSHIP_ID" "${MEMBERSHIP_NAME}"
  echo "${MEMBERSHIP_NAME}"
}

generate_secret_name() {
  local SECRET_NAME; SECRET_NAME="${1}"

  SECRET_NAME="$(sanitize_label "${SECRET_NAME}")"

  if [[ "${#SECRET_NAME}" -gt "${KUBE_TAG_MAX_LEN}" ]]; then
    local DIGEST
    DIGEST="$(echo "${SECRET_NAME}" | sha256sum | head -c20 || true)"
    SECRET_NAME="${SECRET_NAME:0:42}-${DIGEST}"
  fi

  echo "${SECRET_NAME}"
}

register_cluster() {
  if is_cluster_registered; then return; fi

  if is_gcp; then
    if can_modify_gcp_components; then
      enable_workload_identity
    else
      exit_if_no_workload_identity
    fi
  fi

  if can_modify_gcp_iam_roles; then
    bind_user_to_iam_policy "$(required_iam_roles_registration)" "$(local_iam_user)"
  else
    exit_if_out_of_iam_policy
  fi
  populate_cluster_values

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local GKE_CLUSTER_URI; GKE_CLUSTER_URI="$(context_get-option "GKE_CLUSTER_URI")"
  local MEMBERSHIP_NAME; MEMBERSHIP_NAME="$(generate_membership_name "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}")"
  info "Registering the cluster as ${MEMBERSHIP_NAME}..."
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local KCF; KCF="$(context_get-option "KUBECONFIG")"
  local KCC; KCC="$(context_get-option "CONTEXT")"
  local PRIVATE_ISSUER; PRIVATE_ISSUER="$(context_get-option "PRIVATE_ISSUER")"
  local CA; CA="$(context_get-option "CA")"

  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    ensure_cross_project_service_accounts "${FLEET_ID}" "${PROJECT_ID}"
  fi

  local CMD
  CMD="gcloud container hub memberships register ${MEMBERSHIP_NAME}"
  CMD="${CMD} --project=${FLEET_ID}"
  CMD="${CMD} --enable-workload-identity"
  if is_gcp; then
    CMD="${CMD} --gke-uri=${GKE_CLUSTER_URI}"
  else
    CMD="${CMD} --kubeconfig=${KCF} --context=${KCC}"
  fi
  if [[ "${PRIVATE_ISSUER}" -eq 1 ]]; then
    CMD="${CMD} --has-private-issuer"
  fi
  CMD="${CMD} $(context_get-option "HUB_REGISTRATION_EXTRA_FLAGS")"

  # shellcheck disable=SC2086
  retry 2 run_command ${CMD}
}

add_cluster_labels(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local LABELS; LABELS="$(get_cluster_labels)";
  local WANT; WANT="$(mesh_id_label)"
  local NOTFOUND; NOTFOUND="$(find_missing_strings "${WANT}" "${LABELS}")"

  local PLATFORM; PLATFORM="$(context_get-option "PLATFORM")"

  if [[ -z "${NOTFOUND}" ]]; then return 0; fi

  if [[ -n "${LABELS}" ]]; then
    LABELS="${LABELS},"
  fi
  LABELS="${LABELS}${NOTFOUND}"

  if ! is_gcp; then
    local MEMBERSHIP_NAME; MEMBERSHIP_NAME="$(generate_membership_name "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}")"
    info "Adding labels to ${MEMBERSHIP_NAME}"
    retry 2 gcloud container hub memberships update "${MEMBERSHIP_NAME}" \
      --project="${PROJECT_ID}" \
      --update-labels="${LABELS}"
  else
    info "Adding labels to ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
    retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${CLUSTER_LOCATION}" \
      --update-labels="${LABELS}"
  fi
}

populate_fleet_info() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  if [[ -n "${FLEET_ID}" && \
    -n "${HUB_MEMBERSHIP_ID}" && \
    -n "${HUB_IDP_URL}" ]]; then return; fi

  if ! is_membership_crd_installed; then return; fi
HUB_MEMBERSHIP_ID="$(kubectl get memberships.hub.gke.io membership -o=json | jq .spec.owner.id | sed 's/^\"\/\/\(autopush-\)\{0,1\}gkehub\(.sandbox\)\{0,1\}.googleapis.com\/projects\/\(.*\)\/locations\/global\/memberships\/\(.*\)\"$/\4/g')"
  context_set-option "HUB_MEMBERSHIP_ID" "${HUB_MEMBERSHIP_ID}"
  HUB_IDP_URL="$(kubectl get memberships.hub.gke.io membership -o=jsonpath='{.spec.identity_provider}')"
  context_set-option "HUB_IDP_URL" "${HUB_IDP_URL}"
}

create_istio_namespace() {
  info "Creating istio-system namespace..."

  if istio_namespace_exists; then return; fi

  retry 2 kubectl create ns istio-system
}

label_istio_namespace() {
  local NETWORK_ID; NETWORK_ID="$(context_get-option "NETWORK_ID")"
  local NETWORK_LABEL; NETWORK_LABEL="$(kubectl get ns istio-system -o json | jq -r '.metadata.labels."topology.istio.io/network"')"
  if [[ "${NETWORK_LABEL}" = 'null' ]]; then
    retry 2 kubectl label ns istio-system "topology.istio.io/network=${NETWORK_ID}"
  else
    info "topology.istio.io/network is already set to ${NETWORK_LABEL} and will NOT be overridden."
  fi
}

register_gce_identity_provider() {
  info "Registering GCE Identity Provider in the cluster..."
  context_append "kubectlFiles" "asm/identity-provider/identityprovider-crd.yaml"
  context_append "kubectlFiles" "asm/identity-provider/googleidp.yaml"
}

get_auth_token() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local TOKEN; TOKEN="$(retry 2 gcloud --project="${PROJECT_ID}" auth print-access-token)"
  echo "${TOKEN}"
}
