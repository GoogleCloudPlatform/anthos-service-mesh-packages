# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  CITADEL_MANIFEST="citadel-ca.yaml"
  context_init
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
  context_set-option "CHANNEL" "regular"
  run get_cr_channels
  assert_output "regular"

  context_set-option "CHANNEL" "stable"
  run get_cr_channels
  assert_output "stable"

  context_set-option "CHANNEL" "rapid"
  run get_cr_channels
  assert_output "rapid"

  context_set-option "CHANNEL" ""
  ### [END] Specified by the users ###

  ### [START] channel should be regular and rapid for on-prem ###
  context_set-option "PLATFORM" "multicloud"
  run get_cr_channels
  assert_output --stdin <<EOF
regular
rapid
EOF
  context_set-option "PLATFORM" "gcp"
  ### [END] channel should be regular and rapid for on-prem ###

  ### [START] channel should be regular and rapid for static (no) GKE channel ###
  get_gke_release_channel() {
    echo ""
  }
  run get_cr_channels
  assert_output --stdin <<EOF
regular
rapid
EOF
  ### [END] channel should be regular and rapid for static (no) GKE channel ###

  ### [START] channel should be rapid for rapid GKE channel ###
  get_gke_release_channel() {
    echo "rapid"
  }
  run get_cr_channels
  assert_output "rapid"
  ### [END] channel should be rapid for rapid GKE channel ###

  ### [START] channel should be regular and rapid for regular GKE channel ###
  get_gke_release_channel() {
    echo "regular"
  }
  run get_cr_channels
  assert_output --stdin <<EOF
rapid
regular
EOF
  ### [END] channel should be regular and rapid for regular GKE channel ###

  ### [START] channel should be stable for stable GKE channel ###
  get_gke_release_channel() {
    echo "stable"
  }
  run get_cr_channels
  assert_output "stable"
  ### [END] channel should be stable for stable GKE channel ###
}
