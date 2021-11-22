context_init() {
  local CONTEXT_JSON; CONTEXT_JSON=$(cat <<EOF
{
  "flags": {
    "PROJECT_ID": "${PROJECT_ID:-}",
    "CLUSTER_NAME": "${CLUSTER_NAME:-}",
    "CLUSTER_LOCATION": "${CLUSTER_LOCATION:-}",
    "GKE_CLUSTER_URI": "${GKE_CLUSTER_URI:-}",
    "KUBECONFIG": "${KUBECONFIG_FILE:-}",
    "KUBECONFIG_SUPPLIED": "${KUBECONFIG_SUPPLIED:-0}",
    "FLEET_ID": "${FLEET_ID:-}",
    "CA": "${CA:-}",
    "PLATFORM": "${PLATFORM:-}",
    "CONTEXT": "${CONTEXT:-}",
    "CUSTOM_OVERLAY": "${CUSTOM_OVERLAY:-}",
    "OPTIONAL_OVERLAY": "${OPTIONAL_OVERLAY:-}",
    "NETWORK_ID": "${NETWORK_ID:-}",
    "ENABLE_ALL": ${ENABLE_ALL:-0},
    "ENABLE_CLUSTER_ROLES": ${ENABLE_CLUSTER_ROLES:-0},
    "ENABLE_CLUSTER_LABELS": ${ENABLE_CLUSTER_LABELS:-0},
    "ENABLE_GCP_APIS": ${ENABLE_GCP_APIS:-0},
    "ENABLE_GCP_IAM_ROLES": ${ENABLE_GCP_IAM_ROLES:-0},
    "ENABLE_GCP_COMPONENTS": ${ENABLE_GCP_COMPONENTS:-0},
    "ENABLE_REGISTRATION": ${ENABLE_REGISTRATION:-0},
    "ENABLE_NAMESPACE_CREATION": ${ENABLE_NAMESPACE_CREATION:-0},
    "ENABLE_MESHCONFIG_INIT": ${ENABLE_MESHCONFIG_INIT:-0},
    "USE_MANAGED_CNI": ${USE_MANAGED_CNI:-0},
    "USE_VPCSC": ${USE_VPCSC:-0},
    "DISABLE_CANONICAL_SERVICE": ${DISABLE_CANONICAL_SERVICE:-0},
    "TRUST_FLEET_IDENTITY": ${TRUST_FLEET_IDENTITY:-1},
    "PRINT_CONFIG": ${PRINT_CONFIG:-0},
    "NON_INTERACTIVE": ${NON_INTERACTIVE:-0},
    "SERVICE_ACCOUNT": "${SERVICE_ACCOUNT:-}",
    "KEY_FILE": "${KEY_FILE:-}",
    "OUTPUT_DIR": "${OUTPUT_DIR:-}",
    "CA_CERT": "${CA_CERT:-}",
    "CA_KEY": "${CA_KEY:-}",
    "CA_ROOT": "${CA_ROOT:-}",
    "CA_CHAIN": "${CA_CHAIN:-}",
    "CA_NAME": "${CA_NAME:-}",
    "DRY_RUN": ${DRY_RUN:-0},
    "ONLY_VALIDATE": ${ONLY_VALIDATE:-0},
    "VALIDATION_ERROR": ${VALIDATION_ERROR:-0},
    "ONLY_ENABLE": ${ONLY_ENABLE:-0},
    "VERBOSE": ${VERBOSE:-0},
    "MANAGED": ${MANAGED:-0},
    "LEGACY": ${LEGACY:-0},
    "MANAGED_SERVICE_ACCOUNT": "${MANAGED_SERVICE_ACCOUNT:-}",
    "PRINT_HELP": ${PRINT_HELP:-0},
    "PRINT_VERSION": ${PRINT_VERSION:-0},
    "CUSTOM_CA": ${CUSTOM_CA:-0},
    "USE_HUB_WIP": ${USE_HUB_WIP:-1},
    "USE_VM": ${USE_VM:-0},
    "HUB_MEMBERSHIP_ID": "${HUB_MEMBERSHIP_ID:-}",
    "CUSTOM_REVISION": ${CUSTOM_REVISION:-0},
    "TRUST_DOMAIN_ALIASES": "${TRUST_DOMAIN_ALIASES:-}",
    "WI_ENABLED": ${WI_ENABLED:-0},
    "HTTPS_PROXY": "${HTTPS_PROXY:-}",
    "INSTALL_EXPANSION_GATEWAY": ${INSTALL_EXPANSION_GATEWAY:-0},
    "INSTALL_IDENTITY_PROVIDER": ${INSTALL_IDENTITY_PROVIDER:-0},
    "EXPERIMENTAL": ${EXPERIMENTAL:-0},
    "KC_VIA_CONNECT": ${KC_VIA_CONNECT:-0},
    "CHANNEL": "${CHANNEL:-}"
  },
  "istioctlFiles": [],
  "kubectlFiles": [],
  "mcpOptions": [],
  "clustersInfo": [],
  "clusterRegistrations": [],
  "clusterContexts": [],
  "kubeconfigFiles": []
}
EOF
)

  context_FILE_LOCATION="$(mktemp)"; readonly context_FILE_LOCATION
  export context_FILE_LOCATION

  echo "${CONTEXT_JSON}" | jq -S '.' >| "${context_FILE_LOCATION}"

  context_post-init
}

# Function to be called at the end of context_init
# that houses any secondary initialization or cleanup
# steps after the context has been initialized.
context_post-init() {

  # Certain multicloud clusters require kubectl to use
  # a proxy. If this proxy is exported, the gcloud will
  # break.
  unset HTTPS_PROXY
}

context_get-option() {
  local OPTION; OPTION="${1}"

  jq -r --arg OPTION "${OPTION}" '.flags[$OPTION]' "${context_FILE_LOCATION}"
}

context_set-option() {
  local OPTION; OPTION="${1}"
  local VALUE; VALUE="${2}"
  local TEMP_FILE; TEMP_FILE="$(mktemp)"

  jq -S --arg OPTION "${OPTION}" --arg VALUE "${VALUE}" \
  '.flags[$OPTION]=($VALUE | try tonumber catch $VALUE)' "${context_FILE_LOCATION}" >| "${TEMP_FILE}" \
  && mv "${TEMP_FILE}" "${context_FILE_LOCATION}"
}

context_append() {
  local KEY; KEY="${1}"
  local VALUE; VALUE="${2}"
  local TEMP_FILE; TEMP_FILE="$(mktemp)"

  jq -S --arg KEY "${KEY}" --arg VALUE "${VALUE}" '.[$KEY] += [$VALUE]' "${context_FILE_LOCATION}" >| "${TEMP_FILE}" \
  && mv "${TEMP_FILE}" "${context_FILE_LOCATION}"
}

context_list() {
  local KEY; KEY="${1}"
  jq -S -r --arg KEY "${KEY}" '.[$KEY][]' "${context_FILE_LOCATION}"
}
