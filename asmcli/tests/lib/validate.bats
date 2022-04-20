# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  context_init
  GKE_PROJECT_ID="project-id"
  GKE_CLUSTER_NAME="cluster-name"
  GKE_CLUSTER_LOCATION="cluster-location"
  CG_CONTEXT_NAME="connectgateway_project-id_cgw"
  GKE_CONTEXT_NAME="gke_${GKE_PROJECT_ID}_${GKE_CLUSTER_LOCATION}_${GKE_CLUSTER_NAME}"
}

@test "VALIDATE: determines Connect gateway usage correctly" {
  context_set-option "KC_VIA_CONNECT" 0

  run validate_kubeconfig_context "${CG_CONTEXT_NAME}"
  assert_success
  run context_get-option "KC_VIA_CONNECT"
  assert_output 1

  context_set-option "KC_VIA_CONNECT" 0
  run validate_kubeconfig_context "${GKE_CONTEXT_NAME}"
  assert_success
  run context_get-option "KC_VIA_CONNECT"
  assert_output 0
}

@test "VALIDATE: parses GKE information correctly from kc context" {
  context_set-option "KC_VIA_CONNECT" 0
  context_set-option "PLATFORM" gcp

  run validate_kubeconfig_context "${GKE_CONTEXT_NAME}"
  assert_success
  run context_get-option "PROJECT_ID"
  assert_output "${GKE_PROJECT_ID}"
  run context_get-option "CLUSTER_NAME"
  assert_output "${GKE_CLUSTER_NAME}"
  run context_get-option "CLUSTER_LOCATION"
  assert_output "${GKE_CLUSTER_LOCATION}"
}

@test "VALIDATE: node_pool_wi_enabled should skip autopilot cluster" {
  is_autopilot() {
    true
  }

  local RETVAL=0
  _="$(node_pool_wi_enabled)" || RETVAL="${?}"
  [ "${RETVAL}" -eq 0 ]

  is_autopilot() {
    false
  }

  _="$(node_pool_wi_enabled)" || RETVAL="${?}"
  [ "${RETVAL}" -eq 1 ]
}
