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
  if can_modify_gcp_components || \
     can_modify_cluster_labels || \
     can_modify_cluster_roles; then
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

# [START required_apis]
required_apis() {
    local CA; CA="$(context_get-option "CA")"
    cat << EOF
container.googleapis.com
monitoring.googleapis.com
logging.googleapis.com
cloudtrace.googleapis.com
meshtelemetry.googleapis.com
meshconfig.googleapis.com
iamcredentials.googleapis.com
gkeconnect.googleapis.com
gkehub.googleapis.com
cloudresourcemanager.googleapis.com
stackdriver.googleapis.com
EOF
  case "${CA}" in
   mesh_ca)
     echo meshca.googleapis.com
     ;;
   gcp_cas)
     echo privateca.googleapis.com
     ;;
    *);;
  esac

  if [[ "${_CI_I_AM_A_TEST_ROBOT}" -eq 1 ]]; then
    echo compute.googleapis.com
  fi
}
# [END required_apis]

bind_user_to_cluster_admin(){
  info "Querying for core/account..."
  local GCLOUD_USER; GCLOUD_USER="$(gcloud config get-value core/account)"
  info "Binding ${GCLOUD_USER} to cluster admin role..."
  local PREFIX; PREFIX="$(echo "${GCLOUD_USER}" | cut -f 1 -d @)"
  local YAML; YAML="$(retry 5 kubectl create \
    clusterrolebinding "${PREFIX}-cluster-admin-binding" \
    --clusterrole=cluster-admin \
    --user="${GCLOUD_USER}" \
    --dry-run -o yaml)"
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

  info "Enabling required APIs..."
  # shellcheck disable=SC2046
  retry 3 gcloud services enable --project="${PROJECT_ID}" $(required_apis | tr '\n' ' ')
}
