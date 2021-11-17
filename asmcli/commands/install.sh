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

  outro
  info "Successfully installed ASM."
  return 0
}

install_in_cluster_control_plane() {
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if ! does_istiod_exist && [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    info "Installing validation webhook fix..."
    retry 3 kubectl apply --overwrite=true -f "${VALIDATION_FIX_SERVICE}"
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
  fi
}

install_private_ca() {
  # This sets up IAM privileges for the project to be able to access GCP CAS.
  # If modify_gcp_component permissions are not granted, it is assumed that the
  # user has taken care of this, else Istio setup will fail
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local WORKLOAD_IDENTITY; WORKLOAD_IDENTITY="${FLEET_ID}.svc.id.goog:/allAuthenticatedUsers/"
  local CA_LOCATION; CA_LOCATION=$(echo "${CA_NAME}" | cut -f4 -d/)
  local CA_POOL; CA_POOL=$(echo "${CA_NAME}" | cut -f6 -d/)
  local PROJECT; PROJECT=$(echo "${CA_NAME}" | cut -f2 -d/)

  retry 3 gcloud privateca pools add-iam-policy-binding "${CA_POOL}" \
    --project "${PROJECT}" \
    --location "${CA_LOCATION}" \
    --member "group:${WORKLOAD_IDENTITY}" \
    --role "roles/privateca.workloadCertificateRequester"

  retry 3 gcloud privateca pools add-iam-policy-binding "${CA_POOL}" \
    --project "${PROJECT}" \
    --location "${CA_LOCATION}" \
    --member "group:${WORKLOAD_IDENTITY}" \
    --role "roles/privateca.auditor"
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

install_control_plane_revisions() {
  info "Configuring ASM managed control plane revision CR for channels..."
  
  local CHANNEL CR REVISION
  while read -r CHANNEL; do
    read -r CR REVISION<<EOF
$(get_cr_yaml "${CHANNEL}")
EOF
    info "Installing ASM Control Plane Revision CR with ${REVISION} channel in istio-system namespace..."
    retry 3 kubectl apply -f "${CR}"

    if ! is_legacy; then
      info "Waiting for deployment..."
      retry 3 kubectl wait --for=condition=ProvisioningFinished \
        controlplanerevision "${REVISION}" -n istio-system --timeout 600s
    fi
  done <<EOF
$(get_cr_channels)
EOF
}

expose_istiod() {
  # The default istiod service is exposed so that any fallback on the VM side
  # to use the default Istiod service can still connect to the control plane.
  context_append "kubectlFiles" "${EXPOSE_ISTIOD_DEFAULT_SERVICE}"
  context_append "kubectlFiles" "${EXPOSE_ISTIOD_REVISION_SERVICE}"
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

  label_istio_namespace
  if is_managed; then
    install_managed_control_plane
  else
    install_in_cluster_control_plane
  fi

  apply_kube_yamls

  if is_managed; then
    install_control_plane_revisions
  fi

  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi
}
