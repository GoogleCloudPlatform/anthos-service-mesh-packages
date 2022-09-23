# Setting up a test with a shared *.bash file
# Shared procedures/functions should go in that file
setup() {
  load 'unit_test_common.bash'
  _common_setup

  # intercept all gcloud and kubectl with mock
  _intercept_setup
  KUBECONFIG="$(mktemp)"
}

# Potential cleanup work should happen here
teardown() {
  rm "${KUBECONFIG}"
  echo "Cleaned up"
}

@test "MAIN: no arguments returns nonzero exit code" {
  run main
  assert_failure
}

@test "MAIN: --help flag should work" {
  local CMD
  CMD="-h"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: --help flag with verbose should work" {
  local CMD
  CMD="-h -v"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: --version flag should work" {
  local CMD
  CMD="--version"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: run a complete validation pass with valid project id, location, cluster name and ca" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: run a complete validation pass and owner role by itself should pass" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p owner_this_should_pass"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(_CI_I_AM_A_TEST_ROBOT=1 main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: create-mesh should register" {
  local CMD
  CMD="create-mesh"
  CMD="${CMD} this_should_pass"
  CMD="${CMD} this_should_pass/this_should_pass/this_should_pass"
  CMD="${CMD} this_should_pass/this_should_pass/this_should_pass"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: invalid subcommand should fail" {
  local CMD
  CMD="this_is_an_invalid_subcommand"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: non-existing project should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_fail"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: non-existing cluster should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_fail"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: bad CA should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c this_should_fail"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: with only service account should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} -s service-account"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: with only one of key should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} -k keyfile"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: passing enable* flags with validate should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} -e"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: passing custom overlay with --managed should fail" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} --managed"
  CMD="${CMD} --custom-overlay foo.yaml"
  CMD="${CMD} -c mesh_ca"

  local RETVAL=0
  _="$(main ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -ne 0 ]
}

@test "MAIN: passing legacy flag should continue" {
  local CMD
  CMD="validate"
  CMD="${CMD} -l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --legacy"

  local RETVAL=0
  local OUTPUT
  OUTPUT="$(main ${CMD} 2>&1)" || RETVAL="${?}"

  assert_equal "${RETVAL}" 0

  echo "${OUTPUT}" | grep -q 'The legacy option is no longer supported--continuing with normal installation.'
}

@test "MAIN: good case for permissions" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"

  parse_args ${CMD}

  if can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_modify_gcp_components \
    || can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: kubeconfig path is canonicalized" {
  context_init
  touch temp-kc-for-test

  local CMD
  CMD="--kubeconfig temp-kc-for-test"

  APATH="readlink"
  parse_args ${CMD}

  run context_get-option "KUBECONFIG"
  assert_output "${PWD}/temp-kc-for-test"
}

@test "MAIN: --enable-all should grant all permissions" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} -e"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || ! can_modify_cluster_roles \
    || ! can_modify_cluster_labels \
    || ! can_modify_gcp_apis \
    || ! can_modify_gcp_components \
    || ! can_modify_gcp_iam_roles \
    || ! can_register_cluster; then
    exit 1
  fi
}

@test "MAIN: --enable-cluster-labels should only grant the permission to modify the cluster labels" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --enable-cluster-labels"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || can_modify_cluster_roles \
    || ! can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_register_cluster \
    || can_modify_gcp_components \
    || can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: --enable-cluster-roles should only grant the permission to modify the cluster roles" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --enable-cluster-roles"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || ! can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_register_cluster \
    || can_modify_gcp_components \
    || can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: --enable-gcp-apis should only grant the permission to modify the GCP APIs" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --enable-gcp-apis"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || ! can_modify_gcp_apis \
    || can_register_cluster \
    || can_modify_gcp_components \
    || can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: --enable-gcp-components should only grant the permission to modify the GCP components" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --enable-gcp-components"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_register_cluster \
    || ! can_modify_gcp_components \
    || can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: --enable-gcp-iam-roles should only grant the permission to modify the GCP IAM roles" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --enable-gcp-iam-roles"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_register_cluster \
    || can_modify_gcp_components \
    || ! can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: --managed should grant the permissions to modify cluster roles, GCP components and IAM roles" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --managed"

  parse_args ${CMD}

  if ! can_modify_at_all \
    || ! can_modify_cluster_roles \
    || can_modify_cluster_labels \
    || can_modify_gcp_apis \
    || can_register_cluster \
    || ! can_modify_gcp_components \
    || ! can_modify_gcp_iam_roles; then
    exit 1
  fi
}

@test "MAIN: VM and HUB_MESHCA should grant the permission to register the cluster" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --option vm"
  CMD="${CMD} --option hub_meshca"

  parse_args ${CMD}

  if ! can_register_cluster; then
    exit 1
  fi
}

@test "MAIN: VM and --managed should pass" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} --managed"
  CMD="${CMD} --option vm"
  CMD="${CMD} -c mesh_ca"

  parse_args ${CMD}

  local RETVAL=0
  _="$(validate_args ${CMD})" || RETVAL="${?}"

  [ "${RETVAL}" -eq 0 ]
}

@test "MAIN: VM and --managed should grant the permission to register the cluster" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} --option vm"
  CMD="${CMD} --managed"

  parse_args ${CMD}

  if ! can_register_cluster; then
    exit 1
  fi
}

@test "MAIN: VM requires service mesh feature to be enabled" {
  context_init

  local CMD
  CMD="-l this_should_pass"
  CMD="${CMD} -n this_should_pass"
  CMD="${CMD} -p this_should_pass"
  CMD="${CMD} -c mesh_ca"
  CMD="${CMD} -e"
  CMD="${CMD} --option vm"

  parse_args ${CMD}

  if ! needs_service_mesh_feature; then
    exit 1
  fi
}

@test "MAIN: find_missing_strings shouldn't return anything with a trailing comma" {
  read -r HAYSTACK <<EOF
one
two
three
four
EOF

  ANS="$(find_missing_strings "one,four" "${HAYSTACK}")"
  echo "Got ${ANS} when testing find_missing_strings"
  if [[ "${ANS}" != "one,four" ]]; then
    exit 1
  fi
}

@test "MAIN: local_iam_user should detect user correctly" {
  context_init

  context_set-option PROJECT_ID "user"
  TYPE="$(local_iam_user | cut -f 1 -d":")"
  echo "Got type ${TYPE}"

  if [[ "${TYPE}" != "user" ]]; then
    exit 1
  fi
}

@test "MAIN: local_iam_user should detect SA correctly" {
  context_init

  context_set-option PROJECT_ID "sa"
  TYPE="$(local_iam_user | cut -f 1 -d":")"
  echo "Got type ${TYPE}"

  if [[ "${TYPE}" != "serviceAccount" ]]; then
    exit 1
  fi
}

@test "MAIN: local_iam_user should detect not logged in state" {
  context_init

  context_set-option PROJECT_ID "notloggedin"

  FATAL_EXITS=0
  if [[ "$(local_iam_user)" != "user:" ]]; then
    exit 1
  fi
  echo "***"
  FATAL_EXITS=1
}

@test "MAIN: node pool validation should handle zonal, regional pools with mixed types" {
  context_init

  WARNED=0
  NODE_POOL='[
{
  "autoscaling": {
    "enabled": false
  },
  "config": {
    "machineType": "e2-standard-4"
  },
  "initialNodeCount": 1,
  "locations": [
    "us-central1-x",
    "us-central1-y",
    "us-central1-z"
  ]
},
{
  "autoscaling": {
    "enabled": false
  },
  "config": {
    "machineType": "e2-medium"
  },
  "initialNodeCount": 1,
  "locations": [
    "us-central1-z"
  ]
}
]'

  validate_node_pool

  if [[ "${WARNED}" -eq 1 ]]; then
    exit 1
  fi
}

@test "MAIN: CLI dependency validation should fail when compatibility variables are unset" {
  context_init

  WARNED=0
  FATAL_EXITS=0
  AGCLOUD=""
  validate_cli_dependencies
  FATAL_EXITS=1

  if [[ "${WARNED}" -eq 0 ]]; then
    exit 1
  fi
}

@test "MAIN: kpt should be downloaded if system version is not 0.x" {
  if ! needs_kpt; then
    exit 1
  fi
}

@test "MAIN: platform is detected correctly" {
  if [[ "$(get_platform Linux x86_64)" != "linux_amd64" ]]; then
    exit 1
  fi

  if [[ "$(get_platform Darwin x86_64)" != "darwin_amd64" ]]; then
    exit 1
  fi

  if [[ "$(get_platform Darwin arm64)" != "darwin_arm64" ]]; then
    exit 1
  fi

  if [[ "$(get_platform Windows x86_64)" != "" ]]; then
    exit 1
  fi
}
