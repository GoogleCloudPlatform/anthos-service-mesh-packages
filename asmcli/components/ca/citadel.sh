validate_custom_ca() {
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"

  if [[ "${CA}" != "citadel" ]]; then
    fatal "You must select Citadel as the CA in order to use custom certificates."
  fi
  if [[ -z "${CA_ROOT}" || -z "${CA_KEY}" || -z "${CA_CHAIN}" || -z "${CA_CERT}" ]]; then
    fatal "All four certificate options must be present to use a custom cert."
  fi
  while read -r CERT_FILE; do
    if ! [[ -f "${!CERT_FILE}" ]]; then
      fatal "Couldn't find file ${!CERT_FILE}."
    fi
  done <<EOF
CA_CERT
CA_ROOT
CA_KEY
CA_CHAIN
EOF

  CA_CERT="$(apath -f "${CA_CERT}")"; readonly CA_CERT;
  CA_KEY="$(apath -f "${CA_KEY}")"; readonly CA_KEY;
  CA_CHAIN="$(apath -f "${CA_CHAIN}")"; readonly CA_CHAIN;
  CA_ROOT="$(apath -f "${CA_ROOT}")"; readonly CA_ROOT;

  context_set-option "CA_CERT" "${CA_CERT}"
  context_set-option "CA_KEY" "${CA_KEY}"
  context_set-option "CA_CHAIN" "${CA_CHAIN}"
  context_set-option "CA_ROOT" "${CA_ROOT}"

  info "Checking certificate files for consistency..."
  if ! openssl rsa -in "${CA_KEY}" -check >/dev/null 2>/dev/null; then
    fatal "${CA_KEY} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_CERT}" -text -noout >/dev/null; then
    fatal "${CA_CERT} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_CHAIN}" -text -noout >/dev/null; then
    fatal "${CA_CHAIN} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_ROOT}" -text -noout >/dev/null; then
    fatal "${CA_ROOT} failed an openssl consistency check."
  fi

  info "Checking key matches certificate..."
  local CERT_HASH; local KEY_HASH;
  CERT_HASH="$(openssl x509 -noout -modulus -in "${CA_CERT}" | openssl md5)";
  KEY_HASH="$(openssl rsa -noout -modulus -in "${CA_KEY}" | openssl md5)";
  if [[ "${CERT_HASH}" != "${KEY_HASH}" ]]; then
    fatal "Keyfile does not match the given certificate."
    fatal "Cert: ${CA_CERT}"
    fatal "Key: ${CA_KEY}"
  fi
  unset CERT_HASH; unset KEY_HASH;

  info "Verifying certificate chain of trust..."
  if ! openssl verify -trusted "${CA_ROOT}" -untrusted "${CA_CHAIN}" "${CA_CERT}"; then
    fatal "Unable to verify chain of trust."
  fi
}

configure_citadel() {
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  CUSTOM_OVERLAY="${OPTIONS_DIRECTORY}/citadel-ca.yaml,${CUSTOM_OVERLAY}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"
}
