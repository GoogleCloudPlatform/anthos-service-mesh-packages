install_subcommand() {
  # TODO: validate (mesh_ca | citadel | private_ca).
  # TODO: validate (mcp | in-cluster) control plane.

  # TODO: configure (mesh_ca | citadel | private_ca).
  # TODO: configure (mcp | in-cluster) control plane.

  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"

  if [[ "${MANAGED}" -eq 1 ]]; then
    start_managed_control_plane
  else
    install_in_cluster_control_plane
  fi

  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi

  apply_kube_yamls
  outro
}

start_managed_control_plane() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"

  local CR_IMAGE_JSON; CR_IMAGE_JSON="";
  if [[ -n "${_CI_CLOUDRUN_IMAGE_HUB}" ]]; then
    CR_IMAGE_JSON="{\"image\": \"${_CI_CLOUDRUN_IMAGE_HUB}:${_CI_CLOUDRUN_IMAGE_TAG}\"}"
  fi
  retry 2 run_command curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${CR_IMAGE_JSON}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")

  local VALIDATION_URL; local CLOUDRUN_ADDR;
  read -r VALIDATION_URL CLOUDRUN_ADDR <<EOF
$(scrape_managed_urls)
EOF
  kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
  kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"

  info "Configuring base installation for managed control plane..."
  context_append-kube-yaml "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  context_append-kube-yaml "${MANAGED_WEBHOOKS}"

  info "Configuring ASM managed control plane components..."
  print_config >| managed_control_plane_gateway.yaml
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
  local MODE; MODE="$(context_get-option "MODE")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if ! does_istiod_exist && [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    info "Installing validation webhook fix..."
    context_append-kube-yaml "${VALIDATION_FIX_SERVICE}"
  elif [[ "${MODE}" == "upgrade" ]]; then
    cp "${VALIDATION_FIX_SERVICE}" .
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

  local RAW_YAML; RAW_YAML="${REVISION_LABEL}-manifest-raw.yaml"
  local EXPANDED_YAML; EXPANDED_YAML="${REVISION_LABEL}-manifest-expanded.yaml"
  print_config >| "${RAW_YAML}"
  istioctl manifest generate \
    <"${RAW_YAML}" \
    >|"${EXPANDED_YAML}"

  context_set-option "RAW_YAML" "${RAW_YAML}"
  context_set-option "EXPANDED_YAML" "${EXPANDED_YAML}"

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
  local MODE; MODE="$(context_get-option "MODE")"
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


  if [[ "${MODE}" = "migrate" || "${MODE}" = "upgrade" ]]; then
    info "Please verify the new control plane and then: 1) migrate your workloads 2) remove old control plane."
    info "For more information, see:"
    info "https://cloud.google.com/service-mesh/docs/upgrading-gke#redeploying_workloads"
    info "Before removing the old control plane, update the service used by validation if necessary."
    info "If the 'istiod' service has a revision label different than ${REVISION_LABEL}, then apply"
    info "${OUTPUT_DIR}/${VALIDATION_FIX_FILE_NAME} using 'kubectl apply'"
  elif [[ "${MODE}" = "install" ]]; then
    info "To finish the installation, enable Istio sidecar injection and restart your workloads."
    info "For more information, see:"
    info "https://cloud.google.com/service-mesh/docs/proxy-injection"
  fi
  info "The ASM package used for installation can be found at:"
  info "${OUTPUT_DIR}/asm"
  info "The version of istioctl that matches the installation can be found at:"
  info "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}"
  info "A symlink to the istioctl binary can be found at:"
  info "${OUTPUT_DIR}/istioctl"
  if ! is_managed; then
    local RAW_YAML; RAW_YAML="$(context_get-option "RAW_YAML")"
    local EXPANDED_YAML; EXPANDED_YAML="$(context_get-option "EXPANDED_YAML")"
    info "The combined configuration generated for installation can be found at:"
    info "${OUTPUT_DIR}/${RAW_YAML}"
    info "The full, expanded set of kubernetes resources can be found at:"
    info "${OUTPUT_DIR}/${EXPANDED_YAML}"
  else
    info "You can find the gateway config to install with istioctl here:"
    info "${OUTPUT_DIR}/managed_control_plane_gateway.yaml"
  fi

  info "$(starline)"
}
