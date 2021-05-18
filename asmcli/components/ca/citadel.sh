validate_citadel() {
  return
}

configure_citadel() {
  return
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
