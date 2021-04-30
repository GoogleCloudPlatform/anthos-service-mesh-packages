# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load 'unit_test_common.bash'
  _common_setup
}

# Potential cleanup work should happen here
teardown() {
  echo "Cleaned up"
}

@test "test main method with --version returns zero exit code" {
  run main --version
  assert_success
}

@test "test main method with no arguments returns nonzero exit code" {
  run main
  assert_failure
}
