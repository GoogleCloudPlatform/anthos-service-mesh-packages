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

@test "DEPENDENCIES: labels are sanitized correctly" {
  IN="this:should.look@better_"
  WANT="this-should-look-better-"
  OUT="$(sanitize_label "${IN}")"

  assert_equal "${OUT}" "${WANT}"
}
