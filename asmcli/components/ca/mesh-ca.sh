validate_meshca() {
  return
}

configure_meshca() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  # set the trust domain aliases to include both new Hub WIP and old Hub WIP to achieve no downtime upgrade.
  add_trust_domain_alias "${PROJECT_ID}.svc.id.goog"
  add_trust_domain_alias "${PROJECT_ID}.hub.id.goog"
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
