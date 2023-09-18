configure_package() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CA; CA="$(context_get-option "CA")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"
  local USE_VPCSC; USE_VPCSC="$(context_get-option "USE_VPCSC")"
  local ASMCLI_VERSION; ASMCLI_VERSION="$(version_message)"
  local INCLUDES_STACKDRIVER; INCLUDES_STACKDRIVER="$(context_get-option "INCLUDES_STACKDRIVER")"

  info "Configuring kpt package..."
  set_kpt_configured

  populate_cluster_values
  local NETWORK_ID; NETWORK_ID="$(context_get-option "NETWORK_ID")"

  populate_fleet_info

  if is_gcp; then
    kpt cfg set asm gcloud.container.cluster "${CLUSTER_NAME}"
    kpt cfg set asm gcloud.core.project "${PROJECT_ID}"
    kpt cfg set asm gcloud.compute.location "${CLUSTER_LOCATION}"
  else
    configure_off_gcp_gcp_metadata "${HUB_MEMBERSHIP_ID}" "${PROJECT_ID}"

    if [[ "${CA}" == "citadel" && "${INCLUDES_STACKDRIVER}" -eq 0 ]]; then
      kpt cfg set asm anthos.servicemesh.controlplane.monitoring.enabled "false"
    fi
  fi

  kpt cfg set asm gcloud.compute.network "${NETWORK_ID}"
  kpt cfg set asm gcloud.project.environProjectNumber "${PROJECT_NUMBER}"
  kpt cfg set asm anthos.servicemesh.rev "${REVISION_LABEL}"
  kpt cfg set asm anthos.servicemesh.tag "${RELEASE}"
  if [[ -n "${_CI_ASM_IMAGE_LOCATION}" ]]; then
    kpt cfg set asm anthos.servicemesh.hub "${_CI_ASM_IMAGE_LOCATION}"
  fi
  if [[ -n "${_CI_ASM_IMAGE_TAG}" ]]; then
    kpt cfg set asm anthos.servicemesh.tag "${_CI_ASM_IMAGE_TAG}"
  fi

  if [[ -n "${CA_NAME}" && "${CA}" = "gcp_cas" ]]; then
    kpt cfg set asm anthos.servicemesh.external_ca.ca_name "${CA_NAME}"
  fi

  kpt cfg set asm anthos.servicemesh.trustDomain "${FLEET_ID}.svc.id.goog"
  kpt cfg set asm anthos.servicemesh.tokenAudiences "istio-ca,${FLEET_ID}.svc.id.goog"

  if [[ "${USE_VPCSC}" -eq 1 ]]; then
    kpt cfg set asm anthos.servicemesh.managed-controlplane.vpcsc.enabled "true"
  fi

  kpt cfg set asm anthos.servicemesh.created-by "asmcli-${ASMCLI_VERSION//+/.}"

  configure_ca
  configure_control_plane
}

configure_off_gcp_gcp_metadata(){
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="${1}"
  local PROJECT_ID; PROJECT_ID="${2}"
  local MONITORING_CONFIG_JSON;

  MONITORING_CONFIG_JSON=$(get_monitoring_config_membership_json "${HUB_MEMBERSHIP_ID}" "${PROJECT_ID}")
  
  kpt cfg set asm gcloud.core.project "$(echo $MONITORING_CONFIG_JSON | jq '.monitoringConfig.projectId')"
  kpt cfg set asm gcloud.container.cluster "$(echo $MONITORING_CONFIG_JSON | jq '.monitoringConfig.cluster')"
  kpt cfg set asm gcloud.compute.location "$(echo $MONITORING_CONFIG_JSON | jq '.monitoringConfig.location')"
}

configure_kubectl(){
  local CONTEXT; CONTEXT="$(context_get-option "CONTEXT")"
  local KUBECONFIG; KUBECONFIG="$(context_get-option "KUBECONFIG")"
  local KUBECONFIG_SUPPLIED; KUBECONFIG_SUPPLIED="$(context_get-option "KUBECONFIG_SUPPLIED")"

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    local PROJECT_ID; PROJECT_ID="${1}"
    local CLUSTER_LOCATION; CLUSTER_LOCATION="${2}"
    local CLUSTER_NAME; CLUSTER_NAME="${3}"

    info "Fetching/writing GCP credentials to kubeconfig file..."
    KUBECONFIG="${KUBECONFIG}" retry 2 gcloud container clusters get-credentials "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${CLUSTER_LOCATION}"
    context_set-option "KUBECONFIG" "${KUBECONFIG}"
    context_set-option "CONTEXT" "$(kubectl config current-context)"
  fi

  if ! hash nc 2>/dev/null; then
     warn "nc not found, skipping k8s connection verification"
     warn "(Installation will continue normally.)"
     return
  fi

  if is_gcp; then
    verify_connectivity
  fi

  info "kubeconfig set to ${KUBECONFIG}"
  CONTEXT="$(context_get-option "CONTEXT")"
  info "using context ${CONTEXT}"
}
