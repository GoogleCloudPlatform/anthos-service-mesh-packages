# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  CITADEL_MANIFEST="citadel-ca.yaml"
  PROJECT_ID="test-project"
  CLUSTER_NAME="test_cluster"
  CLUSTER_LOCATION="us-east-2a"
  context_init
}

@test "UTIL: Fleet API should work with compatible settings" {
  run context_set-option "EXPLICIT_FLEET_API" "1"
  run context_set-option "CA" "mesh_ca"
  GKE_RELEASE_CHANNEL="regular"
  CHANNEL="regular"
  assert use_fleet_api
}

@test "UTIL: Fleet API should only work when requested" {
  run context_set-option "CA" "mesh_ca"
  GKE_RELEASE_CHANNEL="regular"
  CHANNEL="regular"
  refute use_fleet_api
}

@test "UTIL: Fleet API should not work with stable channel" {
  run context_set-option "EXPLICIT_FLEET_API" "1"
  run context_set-option "CA" "mesh_ca"
  GKE_RELEASE_CHANNEL="stable"
  CHANNEL="stable"
  run use_fleet_api
  assert_failure
}

@test "UTIL: Fleet API should not work with mismatched channels" {
  run context_set-option "EXPLICIT_FLEET_API" "1"
  run context_set-option "CA" "mesh_ca"
  GKE_RELEASE_CHANNEL="rapid"
  CHANNEL="regular"
  run use_fleet_api
  assert_failure
}

@test "UTIL: Fleet API should not work with CAS" {
  run context_set-option "EXPLICIT_FLEET_API" "1"
  run context_set-option "CA" "managed_cas"
  GKE_RELEASE_CHANNEL="regular"
  CHANNEL="regular"
  run use_fleet_api
  assert_failure
}

@test "UTIL: Citadel CA should include citadel-ca overlay" {
  run context_set-option "CA" "citadel"
  run gen_install_params
  assert_output --partial "citadel-ca.yaml"
}

@test "UTIL: Mesh CA should not include citadel-ca overlay" {
  run context_set-option "CA" "meshca"
  run gen_install_params
  refute_output --partial "citadel-ca.yaml"
}

@test "UTIL: validation error should correctly increment the error count" {
  context_set-option "ONLY_VALIDATE" 1

  run context_get-option "VALIDATION_ERROR"
  assert_output 0

  run validation_error "this is a test"
  run context_get-option "VALIDATION_ERROR"
  assert_output 1

  run validation_error "this is another test"
  run context_get-option "VALIDATION_ERROR"
  assert_output 2
}

@test "UTIL: context's cluster uses the default set context" {
  run get_context_cluster <<EOF
      cluster1       gke_gzip-dev_us-central1-c_cluster1       gke_gzip-dev_us-central1-c_cluster1       
      cluster2       gke_gzip-dev_us-central1-c_cluster2       gke_gzip-dev_us-central1-c_cluster2       
*     cluster3       gke_gzip-dev_us-central1-c_cluster3       gke_gzip-dev_us-central1-c_cluster3       
EOF
  assert_output "gke_gzip-dev_us-central1-c_cluster3"
}

@test "UTIL: channels should be determined by GKE release channel" {

  ### [START] Specified by the users ###
  get_gke_release_channel() {
    echo "regular"
  }
  context_set-option "CHANNEL" "regular"
  run get_cr_channel
  assert_output "regular"

  context_set-option "CHANNEL" "stable"
  run get_cr_channel
  assert_output "regular"

  context_set-option "CHANNEL" "rapid"
  run get_cr_channel
  assert_output "regular"

  context_set-option "CHANNEL" ""
  ### [END] Specified by the users ###

  ### [START] channel should be regular for on-prem ###
  context_set-option "PLATFORM" "multicloud"
  run get_cr_channel
  assert_output --stdin <<EOF
regular
EOF
  context_set-option "PLATFORM" "gcp"
  ### [END] channel should be regular for on-prem ###

  ### [START] channel should be regular for static (no) GKE channel ###
  get_gke_release_channel() {
    echo ""
  }
  run get_cr_channel
  assert_output --stdin <<EOF
regular
EOF
  ### [END] channel should be regular for static (no) GKE channel ###

  ### [START] channel should be rapid for rapid GKE channel ###
  get_gke_release_channel() {
    echo "rapid"
  }
  run get_cr_channel
  assert_output "rapid"
  ### [END] channel should be rapid for rapid GKE channel ###

  ### [START] channel should be regular for regular GKE channel ###
  get_gke_release_channel() {
    echo "regular"
  }
  run get_cr_channel
  assert_output --stdin <<EOF
regular
EOF
  ### [END] channel should be regular for regular GKE channel ###

  ### [START] channel should be stable for stable GKE channel ###
  get_gke_release_channel() {
    echo "stable"
  }
  run get_cr_channel
  assert_output "stable"
  ### [END] channel should be stable for stable GKE channel ###
}

@test "UTIL: KPT_BRANCH is set correctly for release versions" {
  local TEST_VER; TEST_VER="1.1.1-asm.1+config1"
  version_message() {
    echo  "${TEST_VER}"
  }
  init

  if [[ "${TEST_VER}" != "$KPT_BRANCH" ]]; then
    exit 1
  fi
}

@test "UTIL: KPT_BRANCH is set correctly for nonrelease versions" {
  version_message() {
    echo "1.1.1-asm.1+config1+unstable"
  }

  init

  if [[ "main" != "$KPT_BRANCH" ]]; then
    exit 1
  fi
}

@test "UTIL: LOG_FILE_LOCATION is required to write log file" {
  run echo_log "Hello"

  local LOG_FILE_LOCATION; LOG_FILE_LOCATION="$(pwd)/logs.txt"
  run context_set-option "LOG_FILE_LOCATION" "${LOG_FILE_LOCATION}"
  touch "${LOG_FILE_LOCATION}"
  
  run echo_log "World"
  cat "${LOG_FILE_LOCATION}"
  assert_output "World"
  
  rm "${LOG_FILE_LOCATION}"
}

@test "UTIL: Managed Canonical Controller Status is read correctly" {

  _intercept_setup
  run context_set-option "HUB_MEMBERSHIP_ID" "test-cluster"

  #Test Case 1: Unknown Membership State Code for test-cluster
  run context_set-option "FLEET_ID" "unknown-state-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

  #Test Case 2: Error Membership State Code for test-cluster
  run context_set-option "FLEET_ID" "error-state-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

  #Test Case 3: Warning State Code, No CSC Condition for test-cluster
  run context_set-option "FLEET_ID" "warning-non-csc-condition-state-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

  #Test Case 4: OK Membership State Code for test-cluster
  run context_set-option "FLEET_ID" "ok-state-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller working successfully"

  #Test Case 5: Warning State Code, CSC Condition Present  for test-cluster
  run context_set-option "FLEET_ID" "warning-csc-condition-state-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller facing issues"

  #Test Case 6: Warning State Code, CSC Condition, Multi-Cluster Fleet
  run context_set-option "FLEET_ID" "multi-cluster-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Managed Canonical Service Controller facing issues"

  #Test Case 7: Membership Not Found
  run context_set-option "FLEET_ID" "no-membership-fleet"
  run check_managed_canonical_controller_state
  assert_output --partial "Membership state for test-cluster not found"
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

  #Test Case 8: MembershipStates Field Missing from feature state
  run context_set-option "FLEET_ID" "membership-field-missing"
  run check_managed_canonical_controller_state
  assert_output --partial "Membership state for test-cluster not found"
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

  #Test Case 9: gcloud Command Error
  run context_set-option "FLEET_ID" "gcloud-error-result"
  run check_managed_canonical_controller_state
  assert_output --partial "Membership state for test-cluster not found"
  assert_output --partial "Managed Canonical Service Controller status could not be determined"

}