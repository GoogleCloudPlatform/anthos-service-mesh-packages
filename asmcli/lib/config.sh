configure_package() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CA; CA="$(context_get-option "CA")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"
  local USE_MANAGED_CNI; USE_MANAGED_CNI="$(context_get-option "USE_MANAGED_CNI")"
  local USE_VPCSC; USE_VPCSC="$(context_get-option "USE_VPCSC")"

  info "Configuring kpt package..."

  populate_cluster_values
  local NETWORK_ID; NETWORK_ID="$(context_get-option "NETWORK_ID")"

  populate_fleet_info

  if is_gcp; then
    kpt cfg set asm gcloud.container.cluster "${CLUSTER_NAME}"
    kpt cfg set asm gcloud.core.project "${PROJECT_ID}"
    kpt cfg set asm gcloud.compute.location "${CLUSTER_LOCATION}"
  else
    kpt cfg set asm gcloud.core.project "${FLEET_ID}"
    if [[ -n "${HUB_MEMBERSHIP_ID}" ]]; then
      kpt cfg set asm gcloud.container.cluster "${HUB_MEMBERSHIP_ID}"
    else
      kpt cfg set asm gcloud.container.cluster "cluster" # default off-GCP cluster name
    fi
    # "global" is the current default value for off-GCP
    kpt cfg set asm gcloud.compute.location "global"
    if [[ "${CA}" == "citadel" ]]; then
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
  if [[ "${CA}" == "mesh_ca" ]]; then
    kpt cfg set asm anthos.servicemesh.spiffeBundleEndpoints "${FLEET_ID}.svc.id.goog|https://storage.googleapis.com/mesh-ca-resources/spiffe_bundle.json"
  fi

  if [[ "${USE_VM}" -eq 1 ]] && [[ "${_CI_NO_REVISION}" -eq 0 ]]; then
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod-${REVISION_LABEL}.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod-${REVISION_LABEL}.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs-${REVISION_LABEL}"
  fi
  
  if [[ "${USE_MANAGED_CNI}" -eq 1 ]]; then
    kpt cfg set asm anthos.servicemesh.use-managed-cni "true"
  fi
  if [[ "${USE_VPCSC}" -eq 1 ]]; then
    kpt cfg set asm anthos.servicemesh.managed-controlplane.vpcsc.enabled "true"
  fi

  configure_ca
  configure_control_plane
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
