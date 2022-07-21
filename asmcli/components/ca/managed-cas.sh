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

  # The enablement sometimes fails with an error (an example error is attached below).
  # Therefore, the enablement is conducted with retries.
  # "error": {
  #    "code": 429,
  #    "message": "Too many requests are currently being executed, try again later.",
  #    "status": "RESOURCE_EXHAUSTED",
  #    "details": [...]
  info "The enablement may take a few minutes ..."
  for i in {1..3}; do
    curl -H "Authorization: Bearer ${AUTHTOKEN}" \
       -X PATCH -H "Content-Type: application/json" -H "Accept: application/json" \
       -d "${ENABLEFEATURE}" "https://${GKEHUB_API}/v1alpha/projects/${FLEET_ID}/locations/global/features/workloadcertificate?update_mask=membership_specs"
    sleep 60
  done
}

x_wait_for_gke_hub_api_enablement() {
  info "Wait 3 minutes for GKE HUB API enablement to propagate to the systems ..."
  sleep 180
}

x_wait_for_enabling_workload_certificates() {
  local GKEHUB_API; GKEHUB_API="$1"
  local FLEET_ID; FLEET_ID="$2"

  info "Waiting for the workload certificates enablement on cluster. This may take up to 20 minutes ..."
  # Enabling workload certificate feature on a cluster will result in
  # the cluster restarting and the cluster becoming unreachable for minutes.
  # The cluster restart may happen at a random time after the enablement.
  # The time to complete a cluster restart varies based on cluster region and size.
  # Therefore, wait 15 minutes before checking the connection to k8s is recovered.
  sleep 900

  # Checking the k8s cluster is reachable and the gke-spiffe-node-agent is present for the workload certificate.
  local REACHABLE; REACHABLE=0
  for i in {1..3}; do
    local OUT; OUT=$(kubectl get ds -n kube-system gke-spiffe-node-agent 2>/dev/null | grep -i "gke-spiffe-node-agent" || true)
    if [[ -z "$OUT" ]]; then
      info "The k8s cluster is unreachable or gke-spiffe-node-agent is not present, try again ..."
      sleep 60
    else
      info "The k8s cluster is reachable and gke-spiffe-node-agent is present"
      REACHABLE=1
      break
    fi
  done
  if [[ "${REACHABLE}" -eq 0 ]]; then
    fatal "The k8s cluster is unreachable or gke-spiffe-node-agent is not present, exit."
  fi

  # Check the status of workload certificate feature
  local ENABLED; ENABLED=0
  for i in {1..2}; do
    local OUT; OUT="$(curl -H "X-Goog-User-Project: ${FLEET_ID}" \
      -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://${GKEHUB_API}/v1alpha/projects/${FLEET_ID}/locations/global/features/workloadcertificate" 2>/dev/null | \
      grep -i "certificateManagement.*ENABLED")"
    if [[ -z "$OUT" ]]; then
      info "Workload certificate management is not enabled, try again ..."
      sleep 60
    else
      info "Workload certificate management is enabled."
      ENABLED=1
      break
    fi
  done
  if [[ "${ENABLED}" -eq 0 ]]; then
    fatal "The workload certificate management is not enabled. The workload certificates may not work until the management is enabled. Exit."
  fi
}

x_install_managed_cas_for_mcp() {
  info "Configuring managed CAS for managed control plane..."

  context_append "mcpOptions" "CA=MANAGEDCAS"
}
