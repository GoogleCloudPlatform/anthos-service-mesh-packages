# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load '../unit_test_common.bash'
  _common_setup
  PROJECT_ID="this-is-a-test-project"
  CLUSTER_NAME="this-is-a-test-cluster"
  CLUSTER_LOCATION="us-east-2a"
  context_init
}

# Potential cleanup work should happen here
teardown() {
  rm "${context_FILE_LOCATION}"
  echo "Cleaned up"
}

@test "CONTEXT: test context_FILE_LOCATION initialized with environment variables" {
  run context_get-option "PROJECT_ID"
  assert_output "${PROJECT_ID}"

  run context_get-option "CLUSTER_NAME"
  assert_output "${CLUSTER_NAME}"

  run context_get-option "CLUSTER_LOCATION"
  assert_output "${CLUSTER_LOCATION}"
}

@test "CONTEXT: test context_FILE_LOCATION getter and setter on numeric values" {
  run context_get-option "ENABLE_ALL"
  assert_output 0

  run context_set-option "ENABLE_ALL" 1
  assert_success

  run context_get-option "ENABLE_ALL"
  assert_output 1
}

@test "CONTEXT: test context_FILE_LOCATION getter and setter on string values" {
  run context_get-option "CA"
  assert_output ""

  run context_set-option "CA" "meshca"
  assert_success

  run context_get-option "CA"
  assert_output "meshca"
}

@test "CONTEXT: test context_FILE_LOCATION append a istioctl file" {
  run context_list "istioctlFiles"
  assert_output ""

  run context_append "istioctlFile" "istio-1.yaml"
  assert_success

  run context_list "istioctlFile"
  assert_output "istio-1.yaml"
}

@test "CONTEXT: test context_FILE_LOCATION append a kubectl file" {
  run context_list "kubectlFiles"
  assert_output ""

  run context_append "kubectlFiles" "kube-1.yaml"
  assert_success

  run context_list "kubectlFiles"
  assert_output "kube-1.yaml"
}

@test "CONTEXT: test context_FILE_LOCATION append a cluster info" {
  run context_list "clustersInfo"
  assert_output ""

  run context_append "clustersInfo" "my-project us-central1-c my-cluster"
  assert_success

  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME
  read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
$(context_list "clustersInfo")
EOF
  assert_equal "${PROJECT_ID}" "my-project"
  assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
  assert_equal "${CLUSTER_NAME}" "my-cluster"
}

@test "CONTEXT: test context_FILE_LOCATION append a cluster registration" {
  run context_list "clusterRegistrations"
  assert_output ""

  run context_append "clusterRegistrations" "my-project us-central1-c my-cluster https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"
  assert_success

  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI
  read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI <<EOF
$(context_list "clusterRegistrations")
EOF
  assert_equal "${PROJECT_ID}" "my-project"
  assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
  assert_equal "${CLUSTER_NAME}" "my-cluster"
  assert_equal "${GKE_CLUSTER_URI}" "https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"
}

@test "CONTEXT: test context_FILE_LOCATION append multiple istioctl files" {
  run context_list "istioctlFiles"
  assert_output ""

  run context_append "istioctlFiles" "istio-1.yaml"
  assert_success

  run context_list "istioctlFiles"
  assert_output "istio-1.yaml"

  run context_append "istioctlFiles" "istio-2.yaml"
  assert_success

  run context_list "istioctlFiles"
  assert_output --stdin <<EOF
istio-1.yaml
istio-2.yaml
EOF
}

@test "CONTEXT: test context_FILE_LOCATION append multiple kubectl files" {
  run context_list "kubectlFiles"
  assert_output ""

  run context_append "kubectlFiles" "kube-1.yaml"
  assert_success

  run context_list "kubectlFiles"
  assert_output "kube-1.yaml"

  run context_append "kubectlFiles" "kube-2.yaml"
  assert_success

  run context_list "kubectlFiles"
  assert_output --stdin <<EOF
kube-1.yaml
kube-2.yaml
EOF
}

@test "CONTEXT: test context_FILE_LOCATION append multiple clusters info" {
  run context_list "clustersInfo"
  assert_output ""

  run context_append "clustersInfo" "my-project us-central1-c my-cluster"
  assert_success

  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME
  read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
$(context_list "clustersInfo")
EOF
  assert_equal "${PROJECT_ID}" "my-project"
  assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
  assert_equal "${CLUSTER_NAME}" "my-cluster"

  run context_append "clustersInfo" "my-project us-central1-c my-cluster"
  assert_success

  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME; do
    assert_equal "${PROJECT_ID}" "my-project"
    assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
    assert_equal "${CLUSTER_NAME}" "my-cluster"
  done <<EOF
$(context_list "clustersInfo")
EOF
}

@test "CONTEXT: test context_FILE_LOCATION append multiple cluster registrations" {
  run context_list "clusterRegistrations"
  assert_output ""

  run context_append "clusterRegistrations" "my-project us-central1-c my-cluster https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"
  assert_success

  local PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI
  read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI <<EOF
$(context_list "clusterRegistrations")
EOF
  assert_equal "${PROJECT_ID}" "my-project"
  assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
  assert_equal "${CLUSTER_NAME}" "my-cluster"
  assert_equal "${GKE_CLUSTER_URI}" "https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"

  run context_append "clusterRegistrations" "my-project us-central1-c my-cluster https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"
  assert_success

  while read -r PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME GKE_CLUSTER_URI; do
    assert_equal "${PROJECT_ID}" "my-project"
    assert_equal "${CLUSTER_LOCATION}" "us-central1-c"
    assert_equal "${CLUSTER_NAME}" "my-cluster"
    assert_equal "${GKE_CLUSTER_URI}" "https://container.googleapis.com/v1/projects/my-project/locations/us-central1-c/clusters/my-cluster"
  done <<EOF
$(context_list "clusterRegistrations")
EOF
}

@test "CONTEXT: test missing values in non-interactive mode will fail fast" {
  context_set-option "NON_INTERACTIVE" 1
  run has_value "FLEET_ID"
  assert_failure
  context_set-option "NON_INTERACTIVE" 0
}

@test "CONTEXT: test not-missing values in non-interactive mode will succeed" {
  context_set-option "NON_INTERACTIVE" 1
  run has_value "PROJECT_ID"
  assert_success
}

@test "CONTEXT: test missing values in interactive will read from stdin" {
  local FLEET_ID; FLEET_ID="111111"
  has_value "FLEET_ID" << EOF
${FLEET_ID}
EOF
  assert_equal $(context_get-option "FLEET_ID") "${FLEET_ID}"
  context_set-option "FLEET_ID" ""
}

@test "CONTEXT: test that context_set-option and context_get-option properly save and recover large numbers" {
  run context_set-option "TEST_VALUE" "1661901090017863022"
  assert_success
  assert_equal $(context_get-option "TEST_VALUE") "1661901090017863022"
}

@test "CONTEXT: test that context_set-option and context_get-option properly save and recover small numbers" {
  run context_set-option "TEST_VALUE" "123"
  assert_success
  assert_equal $(context_get-option "TEST_VALUE") "123"
}

@test "CONTEXT: test that context_set-option and context_get-option properly save and recover small text" {
  run context_set-option "TEST_VALUE" "blah"
  assert_success
  assert_equal $(context_get-option "TEST_VALUE") "blah"
}

@test "CONTEXT: test that context_set-option and context_get-option properly save and recover long text" {
  LONGTEXT="$(head -c 10000 /dev/zero | tr '\0' '\141')"
  run context_set-option "TEST_VALUE" "${LONGTEXT}"
  assert_success
  assert_equal $(context_get-option "TEST_VALUE") "${LONGTEXT}"
}
