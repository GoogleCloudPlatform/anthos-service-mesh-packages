validate_private_ca() {
  return
}

configure_private_ca() {
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"

  kpt cfg set asm anthos.servicemesh.external_ca.ca_name "${CA_NAME}"
}
