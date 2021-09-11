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
  local TRUSTED_GCP_PROJECTS; TRUSTED_GCP_PROJECTS="$(context_get-option "TRUSTED_GCP_PROJECTS")"

  # Set the trust domain aliases to include both new Hub WIP and old Hub WIP to achieve no downtime upgrade.
  add_trust_domain_alias "${FLEET_ID}.svc.id.goog"
  add_trust_domain_alias "${FLEET_ID}.hub.id.goog"
  if [[ "${FLEET_ID}" != "${PROJECT_ID}" ]]; then
    add_trust_domain_alias "${PROJECT_ID}.svc.id.goog"
  fi
  if [[ -n "${TRUSTED_GCP_PROJECTS}" ]]; then
    # Gather the trust domain aliases from projects.
    while IFS=',' read -ra TRUSTED_GCP_PROJECT_IDS; do
      for trusted_gcp_project_id in "${TRUSTED_GCP_PROJECT_IDS[@]}"; do
        add_trust_domain_alias "${trusted_gcp_project_id}.svc.id.goog"
      done
    done <<EOF
${TRUSTED_GCP_PROJECTS}
EOF
  fi
  local TRUST_FLEET_IDENTITY; TRUST_FLEET_IDENTITY="$(context_get-option "TRUST_FLEET_IDENTITY")"
  # Patch all clusters in the fleet with fleet workload identity pool as the trust domain aliases
  # for multi-cluster mesh upgrade
  if [[ "$TRUST_FLEET_IDENTITY" -eq 1 ]]; then
    local LOCAL_ORIGINAL_TRUST_DOMAIN;
    local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
    # When it is the upgrade case, find the original trust domain in the local cluster
    if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
      local REVISION; REVISION="$(retry 2 kubectl -n istio-system get pod -l istio=istiod \
        -o jsonpath='{.items[].spec.containers[].env[?(@.name=="REVISION")].value}')"
      LOCAL_ORIGINAL_TRUST_DOMAIN="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" \
        -o 'go-template={{index .data "mesh" }}' \
        | grep "trustDomain:" | sed -E 's/trustDomain: //g')"
    fi
    # When it is the upgrade case and the original trust domain is different from the new trust domain FLEET_ID.svc.id.goog
    # we need to patch other clusters in the fleet to include FLEET_ID.svc.id.goog in the istiod's trust domain aliases
    # this will make sure no downtime in cross-cluster load balancing
    if [[ "${USE_HUB_WIP}" -eq 1 && "${LOCAL_ORIGINAL_TRUST_DOMAIN}" != "" && "${LOCAL_ORIGINAL_TRUST_DOMAIN}" != "${FLEET_ID}.svc.id.goog" ]]; then
      local LOCAL_CLUSTER_CONTEXT; LOCAL_CLUSTER_CONTEXT="$(context_get-option "CONTEXT")"
      for CLUSTER_ENDPOINT in $(retry 2 gcloud container hub memberships list --project="${FLEET_ID}" --format="value(endpoint.gkeCluster.resourceLink)"); do
        # Patch only GCP clusters in the fleet
        if [[ "${CLUSTER_ENDPOINT}" == //container.googleapis.com/* ]]; then
          info "Found GCP cluster endpoint ${CLUSTER_ENDPOINT} in the Fleet ${FLEET_ID}"
          local CLUSTER_META; CLUSTER_META="$(echo "${CLUSTER_ENDPOINT}" | sed 's/^\/\/container.googleapis.com\/projects\/\(.*\)\/locations\/\(.*\)\/clusters\/\(.*\)$/\1 \2 \3/g')"
          local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME;
          read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CLUSTER_META}
EOF
          # Do not patch local cluster
          if [[ "${LOCAL_CLUSTER_CONTEXT}" == "gke_${PROJECT_ID}_${CLUSTER_LOCATION}_${CLUSTER_NAME}" ]]; then
            info "Skip patching for local cluster ${LOCAL_CLUSTER_CONTEXT}"
            continue
          fi
          local EXITCODE; EXITCODE=0;
          gcloud container clusters get-credentials "${CLUSTER_NAME}" \
            --project="${PROJECT_ID}" \
            --zone="${CLUSTER_LOCATION}" || EXITCODE=$?
          if [[ "${EXITCODE}" -ne 0 ]]; then
            info "No access to ${CLUSTER_ENDPOINT}. Please make sure the cluster exists and access to the cluster is granted"
          else
            configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
            local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
            # when a remote GCP cluster in the fleet has istiod installed
            if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
              local REVISION; REVISION="$(retry 2 kubectl -n istio-system get pod -l istio=istiod \
              -o jsonpath='{.items[].spec.containers[].env[?(@.name=="REVISION")].value}')"
              # Find remote cluster trust domain
              local REMOTE_TRUST_DOMAIN; REMOTE_TRUST_DOMAIN="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" \
                -o 'go-template={{index .data "mesh" }}' \
                | grep "trustDomain:" | sed -E 's/trustDomain: //g')"
              # Find remote cluster trust domain aliases
              local RAW_REMOTE_TRUST_DOMAINS_ALIASES; RAW_REMOTE_TRUST_DOMAINS_ALIASES="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" \
                -o jsonpath='{.data.mesh}' | sed -e '1,/trustDomainAliases:/ d')"
              local -a REMOTE_TRUST_DOMAIN_ALIASES
              while IFS= read -r TRUST_DOMAINS_ALIAS; do
                if [[ "$TRUST_DOMAINS_ALIAS" =~ "- " ]]; then
                  REMOTE_TRUST_DOMAIN_ALIASES+=("$TRUST_DOMAINS_ALIAS")
                else
                  break
                fi
              done < <(printf '%s\n' "$RAW_REMOTE_TRUST_DOMAINS_ALIASES")

              local FLEET_ALIAS_FOUND; FLEET_ALIAS_FOUND=0
              local LOCAL_ORIGIN_ALIAS_FOUND; LOCAL_ORIGIN_ALIAS_FOUND=0
              for REMOTE_TRUST_DOMAIN_ALIASES in "${REMOTE_TRUST_DOMAIN_ALIASES[@]}"; do
                if [[ "${REMOTE_TRUST_DOMAIN_ALIASES}" == *"- ${FLEET_ID}.svc.id.goog"* ]]; then
                  FLEET_ALIAS_FOUND=1
                fi
                if [[ "${REMOTE_TRUST_DOMAIN_ALIASES}" == *"- ${LOCAL_ORIGINAL_TRUST_DOMAIN}"* ]]; then
                  LOCAL_ORIGIN_ALIAS_FOUND=1
                fi
              done
              # When local cluster's original trust domain is found in the trust domain alias of the remote cluster
              # it means cross-cluster load balancing works before the upgrade. Then it is needed to include the remote
              # trust domain as the trust domain alias and patch the configmap of the remote cluster if the configmap
              # does not have FLEET_ID.svc.id.goog in the trust domain aliases.
              if [[ "${LOCAL_ORIGIN_ALIAS_FOUND}" -eq 1 ]]; then
                add_trust_domain_alias "${REMOTE_TRUST_DOMAIN}"
                if [[ "${FLEET_ALIAS_FOUND}" -eq 0 ]]; then
                  info "Patch istio-${REVISION} configmap trustDomainAliases with ${FLEET_ID}.svc.id.goog"
                  local CONFIGMAP_YAML; CONFIGMAP_YAML="$(retry 2 kubectl -n istio-system get configmap istio-"${REVISION}" -o yaml)"
                  CONFIGMAP_YAML="$(echo "$CONFIGMAP_YAML" | sed '/^    trustDomainAliases:.*/a \    - '"${FLEET_ID}.svc.id.goog"'')"
                  echo "$CONFIGMAP_YAML"| kubectl apply -f - || warn "failed to patch the configmap istio-${REVISION}"
                fi
              fi
            else
              info "Found no ASM deployment in cluster ${CLUSTER_NAME}"
            fi
          fi
        fi
      done
      # Restore to the local cluster's kubernetes context
      local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
      local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
      local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
      gcloud container clusters get-credentials "${CLUSTER_NAME}" \
        --project="${PROJECT_ID}" \
        --zone="${CLUSTER_LOCATION}"
      configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"
    fi
  fi
  # shellcheck disable=SC2046
  kpt cfg set asm anthos.servicemesh.trustDomainAliases $(context_get-option "TRUST_DOMAIN_ALIASES")
}
