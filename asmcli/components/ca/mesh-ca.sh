validate_meshca() {
  return
}

configure_meshca() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    kpt cfg set asm anthos.servicemesh.trustDomain "${FLEET_ID}.svc.id.goog"
    kpt cfg set asm anthos.servicemesh.idp-url "${HUB_IDP_URL}"
  else
    kpt cfg set asm anthos.servicemesh.trustDomain "${PROJECT_ID}.svc.id.goog"
    kpt cfg set asm anthos.servicemesh.idp-url "https://container.googleapis.com/v1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
  fi

  # set the trust domain aliases to include both new Hub WIP and old Hub WIP to achieve no downtime upgrade.
  add_trust_domain_alias "${FLEET_ID}.svc.id.goog"
  add_trust_domain_alias "${FLEET_ID}.hub.id.goog"
  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    add_trust_domain_alias "${PROJECT_ID}.svc.id.goog"
  fi
  if [[ -n "${_CI_TRUSTED_GCP_PROJECTS}" ]]; then
    # Gather the trust domain aliases from projects.
    while IFS=',' read -r trusted_gcp_project; do
      add_trust_domain_alias "${trusted_gcp_project}.svc.id.goog"
    done <<EOF
${_CI_TRUSTED_GCP_PROJECTS}
EOF
  fi

  # shellcheck disable=SC2046
  kpt cfg set asm anthos.servicemesh.trustDomainAliases $(context_get-option "TRUST_DOMAIN_ALIASES")
}
