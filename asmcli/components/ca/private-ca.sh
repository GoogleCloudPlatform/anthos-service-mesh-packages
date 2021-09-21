validate_private_ca() {
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local CA_NAME_TEMPLATE; CA_NAME_TEMPLATE="projects/project_name/locations/ca_region/caPools/ca_pool"

  if [[ -z ${CA_NAME} ]]; then
    fatal "A ca-name must be provided for integration with Google Certificate Authority Service."
  elif [[ $(grep -o "/" <<< "${CA_NAME}" | wc -l) != $(grep -o "/" <<< "${CA_NAME_TEMPLATE}" | wc -l) ]]; then
    fatal "Malformed ca-name. ca-name must be of the form ${CA_NAME_TEMPLATE}."
  elif [[ "$(echo "${CA_NAME}" | cut -f1 -d/)" != "$(echo "${CA_NAME_TEMPLATE}" | cut -f1 -d/)" ]]; then
    fatal "Malformed ca-name. ca-name must be of the form ${CA_NAME_TEMPLATE}."
  fi
}

configure_private_ca() {
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"

  kpt cfg set asm anthos.servicemesh.external_ca.ca_name "${CA_NAME}"
  CUSTOM_OVERLAY="${OPTIONS_DIRECTORY}/private-ca.yaml,${CUSTOM_OVERLAY}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"

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
