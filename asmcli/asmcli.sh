if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
  cat << EOF >&2
WARNING: bash ${BASH_VERSION} does not support several modern safety features.
This script was written with the latest POSIX standard in mind, and was only
tested with modern shell standards. This script may not perform correctly in
this environment.
EOF
  sleep 1
else
  set -u
fi

### Workaround for RHEL/centOS redefining which for whatever reason?

if [[ -f /etc/profile.d/which2.sh ]]; then
  unset -f which
fi

### These are hooks for Cloud Build to be able to use debug/staging images
### when necessary. Don't set these environment variables unless you're testing
### in CI/CD.
_CI_ASM_IMAGE_LOCATION="${_CI_ASM_IMAGE_LOCATION:=}"; readonly _CI_ASM_IMAGE_LOCATION;
_CI_ASM_IMAGE_TAG="${_CI_ASM_IMAGE_TAG:=}"; readonly _CI_ASM_IMAGE_TAG;
_CI_ASM_PKG_LOCATION="${_CI_ASM_PKG_LOCATION:=}"; readonly _CI_ASM_PKG_LOCATION;
_CI_CLOUDRUN_IMAGE_HUB="${_CI_CLOUDRUN_IMAGE_HUB:=}"; readonly _CI_CLOUDRUN_IMAGE_HUB;
_CI_CLOUDRUN_IMAGE_TAG="${_CI_CLOUDRUN_IMAGE_TAG:=}"; readonly _CI_CLOUDRUN_IMAGE_TAG;
_CI_REVISION_PREFIX="${_CI_REVISION_PREFIX:=}"; readonly _CI_REVISION_PREFIX;
_CI_NO_VALIDATE="${_CI_NO_VALIDATE:=0}"; readonly _CI_NO_VALIDATE;
_CI_NO_REVISION="${_CI_NO_REVISION:=0}"; readonly _CI_NO_REVISION;
_CI_ISTIOCTL_REL_PATH="${_CI_ISTIOCTL_REL_PATH:=}"; readonly _CI_ISTIOCTL_REL_PATH;
_CI_BASE_REL_PATH="${_CI_BASE_REL_PATH:=}"; readonly _CI_BASE_REL_PATH;
_CI_TRUSTED_GCP_PROJECTS="${_CI_TRUSTED_GCP_PROJECTS:=}"; readonly _CI_TRUSTED_GCP_PROJECTS;
_CI_CRC_VERSION="${_CI_CRC_VERSION:=0}"; readonly _CI_CRC_VERSION;
_CI_I_AM_A_TEST_ROBOT="${_CI_I_AM_A_TEST_ROBOT:=0}"; readonly _CI_I_AM_A_TEST_ROBOT;

### Internal variables ###
MAJOR="${MAJOR:=1}"; readonly MAJOR;
MINOR="${MINOR:=26}"; readonly MINOR;
POINT="${POINT:=0}"; readonly POINT;
REV="${REV:=11}"; readonly REV;
CONFIG_VER="${CONFIG_VER:="1"}"; readonly CONFIG_VER;
K8S_MINOR=0

### File related constants ###
ASM_VERSION_FILE=""
ASM_SETTINGS_FILE=""
ISTIO_FOLDER_NAME=""
ISTIOCTL_REL_PATH=""
PACKAGE_DIRECTORY=""
OPTIONS_DIRECTORY=""
OPERATOR_MANIFEST=""
BETA_CRD_MANIFEST=""
CITADEL_MANIFEST=""
EXPOSE_ISTIOD_DEFAULT_SERVICE=""
EXPOSE_ISTIOD_REVISION_SERVICE=""
CANONICAL_CONTROLLER_MANIFEST=""

CR_CONTROL_PLANE_REVISION_REGULAR=""
CR_CONTROL_PLANE_REVISION_RAPID=""
CR_CONTROL_PLANE_REVISION_STABLE=""

SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME

PROJECT_NUMBER=""
GCLOUD_USER_OR_SA="${GCLOUD_USER_OR_SA:=}"
KPT_URL=""
KUBECONFIG=""
APATH=""
AKUBECTL=""
AKPT=""
AGCLOUD=""
RELEASE=""
REVISION_LABEL=""
REVISION_LABEL_REGULAR=""
REVISION_LABEL_RAPID=""
REVISION_LABEL_STABLE=""
RELEASE_LINE=""
PREVIOUS_RELEASE_LINE=""
KPT_BRANCH=""
RAW_YAML=""
EXPANDED_YAML=""
NAMESPACE_EXISTS=0
IS_AUTOPILOT=0
NODE_POOL_WI_ENABLED=0

main() {
  if [[ "${*}" = '' ]]; then
    usage_short >&2
    exit 2
  fi

  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  context_init
  init
  case "${1}" in
    install)
      shift 1
      install_subcommand "${@}"
      ;;
    apply)
      shift 1
      context_set-option "NON_INTERACTIVE" 1
      install_subcommand "${@}"
      ;;
    validate)
      shift 1
      validate_subcommand "${@}"
      ;;
    create-mesh)
      shift 1
      create-mesh_subcommand "${@}"
      ;;
    experimental | x)
      shift 1
      experimental_subcommand "${@}"
      ;;
    build-offline-package)
      shift 1
      build-offline-package_subcommand "${@}"
      ;;
    *)
      help_subcommand "${@}"
      ;;
  esac
}
