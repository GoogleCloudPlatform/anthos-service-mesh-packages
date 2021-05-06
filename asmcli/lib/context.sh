context_init() {
  local CONTEXT_JSON; CONTEXT_JSON=$(cat <<EOF
{
  "flags": {
    "PROJECT_ID": "${PROJECT_ID:-}",
    "CLUSTER_NAME": "${CLUSTER_NAME:-}",
    "CLUSTER_LOCATION": "${CLUSTER_LOCATION:-}",
    "MODE": "${MODE:-}",
    "CA": "${CA:-}",
    "KUBECONFIG": "${KUBECONFIG_FILE:-}",
    "CONTEXT": "${CONTEXT:-}",
    "CUSTOM_OVERLAY": "${CUSTOM_OVERLAY:-}",
    "OPTIONAL_OVERLAY": "${OPTIONAL_OVERLAY:-}",
    "ENABLE_ALL": ${ENABLE_ALL:-0},
    "ENABLE_CLUSTER_ROLES": ${ENABLE_CLUSTER_ROLES:-0},
    "ENABLE_CLUSTER_LABELS": ${ENABLE_CLUSTER_LABELS:-0},
    "ENABLE_GCP_APIS": ${ENABLE_GCP_APIS:-0},
    "ENABLE_GCP_IAM_ROLES": ${ENABLE_GCP_IAM_ROLES:-0},
    "ENABLE_GCP_COMPONENTS": ${ENABLE_GCP_COMPONENTS:-0},
    "ENABLE_REGISTRATION": ${ENABLE_REGISTRATION:-0},
    "ENABLE_NAMESPACE_CREATION": ${ENABLE_NAMESPACE_CREATION:-0},
    "DISABLE_CANONICAL_SERVICE": ${DISABLE_CANONICAL_SERVICE:-0},
    "PRINT_CONFIG": ${PRINT_CONFIG:-0},
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
    "ONLY_ENABLE": ${ONLY_ENABLE:-0},
    "VERBOSE": ${VERBOSE:-0},
    "MANAGED": ${MANAGED:-0},
    "MANAGED_SERVICE_ACCOUNT": "${MANAGED_SERVICE_ACCOUNT:-}",
    "PRINT_HELP": ${PRINT_HELP:-0},
    "PRINT_VERSION": ${PRINT_VERSION:-0},
    "CUSTOM_CA": ${CUSTOM_CA:-0},
    "USE_HUB_WIP": ${USE_HUB_WIP:-0},
    "USE_VM": ${USE_VM:-0},
    "ENVIRON_PROJECT_ID": "${ENVIRON_PROJECT_ID:-}",
    "HUB_MEMBERSHIP_ID": "${HUB_MEMBERSHIP_ID:-}",
    "CUSTOM_REVISION": ${CUSTOM_REVISION:-0},
    "WI_ENABLED": ${WI_ENABLED:-0}
  },
  "istioctlFiles": [],
  "kubectlFiles": []
}
EOF
)

  context_FILE_LOCATION="$(mktemp)"; readonly context_FILE_LOCATION
  export context_FILE_LOCATION

  echo "${CONTEXT_JSON}" | jq -S '.' >| "${context_FILE_LOCATION}"
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

context_append-istio-yaml() {
  local YAML; YAML="${1}"
  local TEMP_FILE; TEMP_FILE="$(mktemp)"

  jq -S --arg YAML "${YAML}" '.istioctlFiles += [$YAML]' "${context_FILE_LOCATION}" >| "${TEMP_FILE}" \
  && mv "${TEMP_FILE}" "${context_FILE_LOCATION}"
}

context_list-istio-yamls() {
  jq -S -r '.istioctlFiles[]' "${context_FILE_LOCATION}"
}

context_append-kube-yaml() {
  local YAML; YAML="${1}"
  local TEMP_FILE; TEMP_FILE="$(mktemp)"

  jq -S --arg YAML "${YAML}" '.kubectlFiles += [$YAML]' "${context_FILE_LOCATION}" >| "${TEMP_FILE}" \
  && mv "${TEMP_FILE}" "${context_FILE_LOCATION}"
}

context_list-kube-yamls() {
  jq -S -r '.kubectlFiles[]' "${context_FILE_LOCATION}"
}
