x_configure_managed_cas() {
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"

  CUSTOM_OVERLAY="${OPTIONS_DIRECTORY}/managed_cas.yaml,${CUSTOM_OVERLAY}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"

  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    kpt cfg set asm anthos.servicemesh.idp-url "${HUB_IDP_URL}"
  else
    kpt cfg set asm anthos.servicemesh.idp-url "https://container.googleapis.com/v1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
  fi

  configure_trust_domain_aliases
}

x_enable_workload_certificate_api() {
  local WORKLOAD_CERT_API; WORKLOAD_CERT_API="$1"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  info "Enabling the workload certificate API for ${FLEET_ID} ..."
  retry 2 run_command gcloud services enable --project="${FLEET_ID}" "${WORKLOAD_CERT_API}"
}

x_exit_if_no_auth_token() {
  local AUTHTOKEN; AUTHTOKEN="$(get_auth_token)"
  if [[ -z "${AUTHTOKEN}" ]]; then
    { read -r -d '' MSG; validation_error "${MSG}"; } <<EOF || true
Auth token is not obtained successfully. Please login and
retry, e.g., run 'gcloud auth application-default login' to login.
EOF
  fi
}

x_enable_workload_certificate_on_fleet() {
  local GKEHUB_API; GKEHUB_API="$1"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  info "Enabling the workload identity feature on ${FLEET_ID} ..."
  x_exit_if_no_auth_token
  local AUTHTOKEN; AUTHTOKEN="$(get_auth_token)"

  local BODY; BODY="{
    'spec': {
      'workloadcertificate': {
        'provision_google_ca': 'ENABLED'
      }
    }
  }"

  curl -H "Authorization: Bearer ${AUTHTOKEN}" \
      -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      -d "${BODY}" \
      "https://${GKEHUB_API}/v1alpha/projects/${FLEET_ID}/locations/global/features?feature_id=workloadcertificate"
}

x_enable_workload_certificate_on_membership() {
  local GKEHUB_API; GKEHUB_API="${1}"
  local FLEET_ID; FLEET_ID="${2}"
  local MEMBERSHIP_NAME; MEMBERSHIP_NAME="${3}"

  info "Enabling the workload certificate for the membership ${MEMBERSHIP_NAME}  ..."
  x_exit_if_no_auth_token
  local AUTHTOKEN; AUTHTOKEN="$(get_auth_token)"

  local ENABLEFEATURE; ENABLEFEATURE="{
    'membership_specs': {
      'projects/${FLEET_ID}/locations/global/memberships/${MEMBERSHIP_NAME}': {
        'workloadcertificate': {
          'certificate_management': 'ENABLED'
        }
      }
    }
  }"

  curl -H "Authorization: Bearer ${AUTHTOKEN}" \
     -X PATCH -H "Content-Type: application/json" -H "Accept: application/json" \
     -d "${ENABLEFEATURE}" "https://${GKEHUB_API}/v1alpha/projects/${FLEET_ID}/locations/global/features/workloadcertificate?update_mask=membership_specs"
}

x_install_managed_cas_for_mcp() {
  info "Configuring managed CAS for managed control plane..."

  context_append "mcpOptions" "CA=MANAGEDCAS"
}
