# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  CITADEL_MANIFEST="citadel-ca.yaml"
  OFF_GCP_MANIFEST="off-gcp.yaml"
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

@test "UTIL: non-gcp should include off-gcp overlay" {
  run context_set-option "PLATFORM" "multicloud"
  run gen_install_params
  assert_output --partial "off-gcp.yaml"
}

@test "UTIL: gcp should not include off-gcp overlay" {
  run context_set-option "PLATFORM" "gcp"
  run gen_install_params
  refute_output --partial "off-gcp.yaml"
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
