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
  ### Configure ###
  configure_ca
  configure_control_plane

  ### Install ###
  install_ca
  install_control_plane

  ### Completion ###
  outro
  info "Successfully installed ASM."
  return 0
}

install_managed_components() {
  info "Configuring ASM managed control plane revision CRD..."
  context_append-kube-yaml "${CRD_CONTROL_PLANE_REVISION}"

  info "Configuring base installation for managed control plane..."
  context_append-kube-yaml "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  context_append-kube-yaml "${MANAGED_WEBHOOKS}"

  info "Configuring ASM managed control plane revision CR for channels..."
  context_append-kube-yaml "${CR_CONTROL_PLANE_REVISION_REGULAR}"
  context_append-kube-yaml "${CR_CONTROL_PLANE_REVISION_RAPID}"
  context_append-kube-yaml "${CR_CONTROL_PLANE_REVISION_STABLE}"
}

scrape_managed_urls() {
  local URL
  URL="$(kubectl get mutatingwebhookconfiguration istiod-asm-managed -ojson | jq .webhooks[0].clientConfig.url -r)"

  local VALIDATION_URL
  # shellcheck disable=SC2001
  VALIDATION_URL="$(echo "${URL}" | sed 's/inject.*$/validate/g')"

  local CLOUDRUN_ADDR
  # shellcheck disable=SC2001
  CLOUDRUN_ADDR=$(echo "${URL}" | cut -d'/' -f3)

  echo "${VALIDATION_URL} ${CLOUDRUN_ADDR}"
}

install_in_cluster_control_plane() {
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if ! does_istiod_exist && [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    info "Installing validation webhook fix..."
    context_append-kube-yaml "${VALIDATION_FIX_SERVICE}"
  fi

  local PARAMS
  PARAMS="-f ${OPERATOR_MANIFEST}"
  for yaml_file in $(context_list-istio-yamls); do
    PARAMS="${PARAMS} -f ${yaml_file}"
  done

  if [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    PARAMS="${PARAMS} --set revision=${REVISION_LABEL}"
  fi

  if [[ "${K8S_MINOR}" -eq 15 ]]; then
    PARAMS="${PARAMS} -f ${BETA_CRD_MANIFEST}"
  fi
  PARAMS="${PARAMS} -c ${KUBECONFIG}"
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
  local WORKLOAD_IDENTITY; WORKLOAD_IDENTITY="${WORKLOAD_POOL}[istio-system/istiod-service-account]"
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
  for yaml_file in $(context_list-kube-yamls); do
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
  context_append-kube-yaml "${EXPOSE_ISTIOD_SERVICE}"
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
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  if [[ "${MANAGED}" -eq 1 ]]; then
    configure_managed_control_plane
  fi
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
    install_managed_components
  else
    install_in_cluster_control_plane
  fi

  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi

  apply_kube_yamls
}
