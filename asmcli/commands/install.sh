install_subcommand() {
  ### Preparation ###
  parse_args "${@}"
  validate_args
  prepare_environment

  ### Validate ###
  validate

  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  if [[ "${USE_VM}" -eq 1 ]]; then
    register_gce_identity_provider
  fi

  ### Configure ###
  configure_package
  post_process_istio_yamls

  install
}

install() {
  install_ca
  install_control_plane
  apply_kube_yamls

  outro
  info "Successfully installed ASM."
  return 0
}

install_in_cluster_control_plane() {
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if ! does_istiod_exist && [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    info "Installing validation webhook fix..."
    context_append "kubectlFiles" "${VALIDATION_FIX_SERVICE}"
  fi

  local PARAMS; PARAMS="$(gen_install_params)"

  if [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    PARAMS="${PARAMS} --set revision=${REVISION_LABEL}"
  fi

  PARAMS="${PARAMS} --skip-confirmation"

  info "Installing ASM control plane..."
  # shellcheck disable=SC2086
  retry 5 istioctl install $PARAMS

  # Prevent the stderr buffer from ^ messing up the terminal output below
  sleep 1
  info "...done!"

  print_config >| "${RAW_YAML}"
  istioctl manifest generate \
    <"${RAW_YAML}" \
    >|"${EXPANDED_YAML}"

  if [[ "${USE_VM}" -eq 1 ]]; then
    info "Exposing the control plane for VM workloads..."
    expose_istiod

    # The default istiod service is exposed so that any fallback on the VM side
    # to use the default Istiod service can still connect to the control plane.
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs"
    expose_istiod
  fi
}

install_citadel() {
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"

  info "Installing certificates into the cluster..."
  kubectl create secret generic cacerts -n istio-system \
    --from-file="${CA_CERT}" \
    --from-file="${CA_KEY}" \
    --from-file="${CA_ROOT}" \
    --from-file="${CA_CHAIN}"
}

install_private_ca() {
  # This sets up IAM privileges for the project to be able to access GCP CAS.
  # If modify_gcp_component permissions are not granted, it is assumed that the
  # user has taken care of this, else Istio setup will fail
  local ISTIOD_SERVICE_ACCOUNT
  ISTIOD_SERVICE_ACCOUNT="istiod-${REVISION_LABEL}"
  if [[ "${_CI_NO_REVISION}" -eq 1 ]]; then
    ISTIOD_SERVICE_ACCOUNT="istiod"
  fi
  local WORKLOAD_IDENTITY; WORKLOAD_IDENTITY="${WORKLOAD_POOL}[istio-system/${ISTIOD_SERVICE_ACCOUNT}]"
  local NAME; NAME=$(echo "${CA_NAME}" | cut -f6 -d/)
  local CA_LOCATION; CA_LOCATION=$(echo "${CA_NAME}" | cut -f4 -d/)
  local CA_PROJECT; CA_PROJECT=$(echo "${CA_NAME}" | cut -f2 -d/)

  retry 3 gcloud beta privateca subordinates add-iam-policy-binding "${NAME}" \
    --location "${CA_LOCATION}" \
    --project "${CA_PROJECT}" \
    --member "serviceAccount:${WORKLOAD_IDENTITY}" \
    --role "roles/privateca.certificateManager"
}

does_istiod_exist(){
  local RETVAL; RETVAL=0;
  kubectl get service \
    --request-timeout='20s' \
    -n istio-system \
    istiod 1>/dev/null 2>/dev/null || RETVAL=$?
  return "${RETVAL}"
}

apply_kube_yamls() {
  for yaml_file in $(context_list "kubectlFiles"); do
    info "Applying ${yaml_file}..."
    retry 3 kubectl apply --overwrite=true -f "${yaml_file}"
    sleep 2
  done
}

install_canonical_controller() {
  info "Installing ASM CanonicalService controller in asm-system namespace..."
  retry 3 kubectl apply -f "${CANONICAL_CONTROLLER_MANIFEST}"
  info "Waiting for deployment..."
  retry 3 kubectl wait --for=condition=available --timeout=600s \
      deployment/canonical-service-controller-manager -n asm-system
  info "...done!"
}

expose_istiod() {
  context_append "kubectlFiles" "${EXPOSE_ISTIOD_SERVICE}"
}

outro() {
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"

  info ""
  info "$(starline)"
  istioctl version
  info "$(starline)"
  info "The ASM control plane installation is now complete."
  info "To enable automatic sidecar injection on a namespace, you can use the following command:"
  info "kubectl label namespace <NAMESPACE> istio-injection- istio.io/rev=${REVISION_LABEL} --overwrite"
  info "If you use 'istioctl install' afterwards to modify this installation, you will need"
  info "to specify the option '--set revision=${REVISION_LABEL}' to target this control plane"
  info "instead of installing a new one."

  info "To finish the installation, enable Istio sidecar injection and restart your workloads."
  info "For more information, see:"
  info "https://cloud.google.com/service-mesh/docs/proxy-injection"

  info "The ASM package used for installation can be found at:"
  info "${OUTPUT_DIR}/asm"
  info "The version of istioctl that matches the installation can be found at:"
  info "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}"
  info "A symlink to the istioctl binary can be found at:"
  info "${OUTPUT_DIR}/istioctl"
  if ! is_managed; then
    info "The combined configuration generated for installation can be found at:"
    info "${OUTPUT_DIR}/${RAW_YAML}"
    info "The full, expanded set of kubernetes resources can be found at:"
    info "${OUTPUT_DIR}/${EXPANDED_YAML}"
  fi

  info "$(starline)"
}

configure_ca() {
  local CA; CA="$(context_get-option "CA")"
  case "${CA}" in
    mesh_ca) configure_meshca;;
    gcp_cas) configure_private_ca;;
    citadel) configure_citadel;;
  esac
}

configure_control_plane() {
  :
}

install_ca() {
  local CA; CA="$(context_get-option "CA")"
  case "${CA}" in
    mesh_ca) ;;
    gcp_cas) install_private_ca;;
    citadel) install_citadel;;
  esac
}

install_control_plane() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"

  if [[ "${MANAGED}" -eq 1 ]]; then
    install_managed_control_plane
  else
    install_in_cluster_control_plane
  fi

  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi
}

### Installation functions ###
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
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local HUB_IDP_URL; HUB_IDP_URL="$(context_get-option "HUB_IDP_URL")"

  info "Configuring kpt package..."

  if is_gcp; then
    populate_cluster_values
  fi

  populate_fleet_info

  if is_gcp; then
    kpt cfg set asm gcloud.container.cluster "${CLUSTER_NAME}"
    kpt cfg set asm gcloud.core.project "${PROJECT_ID}"
    kpt cfg set asm gcloud.compute.location "${CLUSTER_LOCATION}"
    kpt cfg set asm gcloud.compute.network "${GCE_NETWORK_NAME}"
  else
    kpt cfg set asm gcloud.core.project "${FLEET_ID}"
  fi

  kpt cfg set asm gcloud.project.environProjectNumber "${PROJECT_NUMBER}"
  kpt cfg set asm anthos.servicemesh.rev "${REVISION_LABEL}"
  kpt cfg set asm anthos.servicemesh.tag "${RELEASE}"
  if [[ -n "${_CI_ASM_IMAGE_LOCATION}" ]]; then
    kpt cfg set asm anthos.servicemesh.hub "${_CI_ASM_IMAGE_LOCATION}"
  fi
  if [[ -n "${_CI_ASM_IMAGE_TAG}" ]]; then
    kpt cfg set asm anthos.servicemesh.tag "${_CI_ASM_IMAGE_TAG}"
  fi

  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    # VM installation uses the latest Hub WIP format
    if [[ "${USE_VM}" -eq 1 ]]; then
      kpt cfg set asm anthos.servicemesh.hubTrustDomain "${FLEET_ID}.svc.id.goog"
      kpt cfg set asm anthos.servicemesh.hub-idp-url "${HUB_IDP_URL}"
    # GKE-on-GCP installation uses legacy Hub WIP format to be consistent with GCP Hub public preview feature
    else
      kpt cfg set asm anthos.servicemesh.hubTrustDomain "${FLEET_ID}.hub.id.goog"
      kpt cfg set asm anthos.servicemesh.hub-idp-url "https://gkehub.googleapis.com/projects/${FLEET_ID}/locations/global/memberships/${HUB_MEMBERSHIP_ID}"
    fi
  fi
  if [[ -n "${CA_NAME}" && "${CA}" = "gcp_cas" ]]; then
    kpt cfg set asm anthos.servicemesh.external_ca.ca_name "${CA_NAME}"
  fi

  if [[ "${USE_VM}" -eq 1 ]] && [[ "${_CI_NO_REVISION}" -eq 0 ]]; then
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod-${REVISION_LABEL}.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod-${REVISION_LABEL}.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs-${REVISION_LABEL}"
  fi
  configure_ca
  configure_control_plane
}
