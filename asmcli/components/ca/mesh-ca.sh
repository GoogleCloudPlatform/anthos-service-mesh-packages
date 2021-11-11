validate_meshca() {
  return
}

configure_meshca() {
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

configure_trust_domain_aliases() {
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"

  # Set the trust domain aliases to include both new Hub WIP and old Hub WIP to achieve no downtime upgrade.
  add_trust_domain_alias "${FLEET_ID}.svc.id.goog"
  add_trust_domain_alias "${FLEET_ID}.hub.id.goog"
  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    add_trust_domain_alias "${PROJECT_ID}.svc.id.goog"
  fi
  if [[ -n "${_CI_TRUSTED_GCP_PROJECTS}" ]]; then
    # Gather the trust domain aliases from projects.
    while IFS=',' read -ra TRUSTED_GCP_PROJECT_IDS; do
      for trusted_gcp_project_id in "${TRUSTED_GCP_PROJECT_IDS[@]}"; do
        add_trust_domain_alias "${trusted_gcp_project_id}.svc.id.goog"
      done
    done <<EOF
${_CI_TRUSTED_GCP_PROJECTS}
EOF
  fi

  local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
  # When it is the upgrade case, include the original trust domain aliases
  if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
    local REVISION; REVISION="$(retry 2 kubectl -n istio-system get pod -l app=istiod \
      -o jsonpath='{.items[].spec.containers[].env[?(@.name=="REVISION")].value}')"
    local REV_NAME; REV_NAME="istio-${REVISION}"
    if [[ "${REVISION}" = default ]]; then
      REV_NAME="istio"
    fi
    local RAW_TRUST_DOMAINS_ALIASES; RAW_TRUST_DOMAINS_ALIASES="$(retry 2 kubectl -n istio-system get configmap "${REV_NAME}" \
      -o jsonpath='{.data.mesh}' | sed -e '1,/trustDomainAliases:/ d')"
    local RAW_TRUST_DOMAINS_ALIAS;
    while IFS= read -r RAW_TRUST_DOMAINS_ALIAS; do
      if [[ "$RAW_TRUST_DOMAINS_ALIAS" =~ "- " ]]; then
        add_trust_domain_alias "${RAW_TRUST_DOMAINS_ALIAS//*- }"
      else
        break
      fi
    done < <(printf '%s\n' "$RAW_TRUST_DOMAINS_ALIASES")
  fi

  # shellcheck disable=SC2046
  kpt cfg set asm anthos.servicemesh.trustDomainAliases $(context_get-option "TRUST_DOMAIN_ALIASES")
}
