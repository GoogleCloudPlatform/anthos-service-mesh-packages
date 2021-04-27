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

@test "test main method --version" {
  run main --version
  assert_success
}

@test "test main method print usage" {
  run main
  assert_failure
}
