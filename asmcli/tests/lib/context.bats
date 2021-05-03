# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  PROJECT_ID="this-is-a-test-project"
  CLUSTER_NAME="this-is-a-test-cluster"
  CLUSTER_LOCATION="us-east-2a"
  CONTEXT_JSON=$(cat <<EOF
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
  context_init "${CONTEXT_JSON}"
}

# Potential cleanup work should happen here
teardown() {
  rm "${context_FILE_LOCATION}"
  echo "Cleaned up"
}

@test "test context_FILE_LOCATION initialized with environment variables" {
  run context_get-option "PROJECT_ID"
  assert_output "${PROJECT_ID}"

  run context_get-option "CLUSTER_NAME"
  assert_output "${CLUSTER_NAME}"

  run context_get-option "CLUSTER_LOCATION"
  assert_output "${CLUSTER_LOCATION}"
}

@test "test context_FILE_LOCATION getter and setter on numeric values" {
  run context_get-option "ENABLE_ALL"
  assert_output 0

  run context_set-option "ENABLE_ALL" 1
  assert_success

  run context_get-option "ENABLE_ALL"
  assert_output 1
}

@test "test context_FILE_LOCATION getter and setter on string values" {
  run context_get-option "MODE"
  assert_output ""

  run context_set-option "MODE" "install"
  assert_success

  run context_get-option "MODE"
  assert_output install
}
