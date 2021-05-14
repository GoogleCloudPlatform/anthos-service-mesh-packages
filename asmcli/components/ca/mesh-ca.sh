validate_meshca() {
  return
}

configure_meshca() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  if [[ -n "${_CI_TRUSTED_GCP_PROJECTS}" ]]; then
    # Gather the trust domain aliases from projects.
    TRUST_DOMAIN_ALIASES="${PROJECT_ID}.svc.id.goog"
    while IFS=',' read -r trusted_gcp_project; do
      TRUST_DOMAIN_ALIASES="${TRUST_DOMAIN_ALIASES} ${trusted_gcp_project}.svc.id.goog"
    done <<EOF
${_CI_TRUSTED_GCP_PROJECTS}
EOF
    # kpt treats words in quotes as a single param, while kpt need ${TRUST_DOMAIN_ALIASES} to be splitting params for a list. If we remove quotes, the lint will complain.
    # eval will translate the quoted TRUST_DOMAIN_ALIASES into params to workaround both.
    run_command eval kpt cfg set asm anthos.servicemesh.trustDomainAliases "${TRUST_DOMAIN_ALIASES}"
  fi
}
