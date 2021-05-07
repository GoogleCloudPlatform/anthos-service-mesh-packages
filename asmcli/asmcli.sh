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

### These are hooks for Cloud Build to be able to use debug/staging images
### when necessary. Don't set these environment variables unless you're testing
### in CI/CD.
_CI_ASM_IMAGE_LOCATION="${_CI_ASM_IMAGE_LOCATION:=}"
_CI_ASM_IMAGE_TAG="${_CI_ASM_IMAGE_TAG:=}"
_CI_ASM_PKG_LOCATION="${_CI_ASM_PKG_LOCATION:=}"
_CI_CLOUDRUN_IMAGE_HUB="${_CI_CLOUDRUN_IMAGE_HUB:=}"
_CI_CLOUDRUN_IMAGE_TAG="${_CI_CLOUDRUN_IMAGE_TAG:=}"
_CI_REVISION_PREFIX="${_CI_REVISION_PREFIX:=}"
_CI_NO_VALIDATE="${_CI_NO_VALIDATE:=0}"
_CI_NO_REVISION="${_CI_NO_REVISION:=0}"
_CI_ISTIOCTL_REL_PATH="${_CI_ISTIOCTL_REL_PATH:=}"
_CI_TRUSTED_GCP_PROJECTS="${_CI_TRUSTED_GCP_PROJECTS:=}"
_CI_ENVIRON_PROJECT_NUMBER="${_CI_ENVIRON_PROJECT_NUMBER:=}"
_CI_CRC_VERSION="${_CI_CRC_VERSION:=0}"
_CI_I_AM_A_TEST_ROBOT="${_CI_I_AM_A_TEST_ROBOT:=0}"

### Internal variables ###
MAJOR="${MAJOR:=1}"; readonly MAJOR;
MINOR="${MINOR:=9}"; readonly MINOR;
POINT="${POINT:=3}"; readonly POINT;
REV="${REV:=2}"; readonly REV;
CONFIG_VER="${CONFIG_VER:="1-unstable"}"; readonly CONFIG_VER;
K8S_MINOR=0

### File related constants ###
VALIDATION_FIX_FILE_NAME="istiod-service.yaml"
ASM_VERSION_FILE=".asm_version"
ISTIO_FOLDER_NAME=""
ISTIOCTL_REL_PATH=""
BASE_REL_PATH=""
PACKAGE_DIRECTORY=""
VALIDATION_FIX_SERVICE=""
OPTIONS_DIRECTORY=""
OPERATOR_MANIFEST=""
BETA_CRD_MANIFEST=""
MANAGED_MANIFEST=""
MANAGED_WEBHOOKS=""
EXPOSE_ISTIOD_SERVICE=""
CANONICAL_CONTROLLER_MANIFEST=""

SCRIPT_NAME="${0##*/}"

PROJECT_NUMBER=""
GKE_CLUSTER_URI=""
GCE_NETWORK_NAME=""
GCLOUD_USER_OR_SA=""
KPT_URL=""
KUBECONFIG=""
CONTEXT=""
APATH=""
AKUBECTL=""
AKPT=""
AGCLOUD=""
ABS_OVERLAYS=""
RELEASE=""
REVISION_LABEL=""
RELEASE_LINE=""
PREVIOUS_RELEASE_LINE=""
KPT_BRANCH=""
NAMESPACE_EXISTS=0
KUBECONFIG_SUPPLIED=0

main() {
  init

  context_init
  parse_args "${@}"
  validate_args

  set_up_local_workspace
  configure_kubectl

  validate_cli_dependencies

  if is_sa; then
    auth_service_account
  fi

  if should_validate || can_modify_at_all; then
    local_iam_user > /dev/null
    validate_gcp_resources
  fi

  if needs_asm && ! necessary_files_exist; then
    download_asm
  fi

  if needs_asm; then
    organize_kpt_files
  fi

  if should_validate && ! is_managed; then
    validate_dependencies
  fi

  if can_modify_gcp_apis; then
    enable_gcloud_apis
  elif should_validate; then
    exit_if_apis_not_enabled
  fi

  if can_register_cluster; then
    register_cluster
  elif should_validate && [[ "$(context_get-option "USE_HUB_WIP")" -eq 1 ]]; then
    exit_if_cluster_unregistered
  fi

  # Managed must be able to set IAM permissions on a generated user, so the flow
  # is a bit different
  if is_managed; then
    if can_modify_gcp_components; then
      enable_workload_identity
      enable_stackdriver_kubernetes
    else
      exit_if_no_workload_identity
      exit_if_stackdriver_not_enabled
    fi
    if can_modify_gcp_iam_roles; then
      bind_user_to_iam_policy "roles/meshconfig.admin" "$(local_iam_user)"
    fi
    if can_modify_at_all; then
      MANAGED_SERVICE_JSON="$(init_meshconfig_managed)"
      MANAGED_SERVICE_ACCOUNT="$(echo "${MANAGED_SERVICE_JSON}" | jq -r .serviceAccount)"
      if [[ -z "${MANAGED_SERVICE_JSON}" || "${MANAGED_SERVICE_ACCOUNT}" == "null" ]]; then
        fatal "Couldn't initialize meshconfig, do you have the required permission resourcemanager.projects.setIamPolicy?"
      fi
      unset MANAGED_SERVICE_JSON
      context_set-option "MANAGED_SERVICE_ACCOUNT" "${MANAGED_SERVICE_ACCOUNT}"
      bind_user_to_iam_policy "$(required_iam_roles_mcp_sa)" "$(iam_user)"
    fi
  else
    if can_modify_gcp_iam_roles; then
      bind_user_to_iam_policy "$(required_iam_roles)" "$(iam_user)"
    elif should_validate; then
      exit_if_out_of_iam_policy
    fi
  fi

  get_project_number
  if can_modify_cluster_labels; then
    add_cluster_labels
  elif should_validate; then
    exit_if_cluster_unlabeled
  fi

  if ! is_managed; then
    if can_modify_gcp_components; then
      enable_workload_identity
      init_meshconfig
      if [[ "$(context_get-option "CA")" = "gcp_cas" ]]; then
        # This sets up IAM privileges for the project to be able to access GCP CAS.
        # If modify_gcp_component permissions are not granted, it is assumed that the
        # user has taken care of this, else Istio setup will fail
        init_gcp_cas
      fi
      enable_stackdriver_kubernetes
      if should_enable_service_mesh_feature; then
        enable_service_mesh_feature
      fi
    elif should_validate; then
      exit_if_no_workload_identity
      exit_if_stackdriver_not_enabled
      if should_enable_service_mesh_feature; then
        exit_if_service_mesh_feature_not_enabled
      fi
    fi
  fi

  if can_modify_cluster_roles; then
    bind_user_to_cluster_admin
  elif should_validate; then
    exit_if_not_cluster_admin
  fi

  if can_create_namespace; then
    create_istio_namespace
  elif should_validate; then
    exit_if_istio_namespace_not_exists
  fi

  if [[ "$(context_get-option "ONLY_VALIDATE")" -eq 1 ]]; then
    info "Successfully validated all requirements to install ASM in this environment."
    return 0
  fi

  if only_enable; then
    info "Successfully performed specified --enable actions."
    return 0
  fi

  if [[ "$(context_get-option "PRINT_CONFIG")" -eq 1 && "$(context_get-option "USE_HUB_WIP")" -eq 1 ]]; then
    populate_environ_info
  fi

  if can_modify_at_all && [[ "$(context_get-option "MANAGED")" -eq 1 ]]; then
    start_managed_control_plane
    configure_package
    install_managed_components
    outro
    return 0
  fi

  if [[ "$(context_get-option "USE_VM")" -eq 1 ]]; then
    register_gce_identity_provider
  fi

  configure_package
  handle_multi_yaml_bug

  if [[ "$(context_get-option "PRINT_CONFIG")" -eq 1 ]]; then
    print_config >&3
    return 0
  fi

  if [[ "$(context_get-option "CUSTOM_CA")" -eq 1 ]]; then
    install_secrets
  fi

  install_asm

  info "Successfully installed ASM."
  return 0
}

init() {
  # BSD-style readlink apparently doesn't have the same -f toggle on readlink
  case "$(uname)" in
    Linux ) APATH="readlink";;
    Darwin) APATH="stat";;
    *);;
  esac

  if [[ "${POINT}" == "alpha" ]]; then
    RELEASE="${MAJOR}.${MINOR}-alpha.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}"
    KPT_BRANCH="${_CI_ASM_KPT_BRANCH:=master}"
  elif [[ "$(version_message)" =~ ^[0-9]+\.[0-9]+\.[0-9]+-asm\.[0-9]+\+config[0-9]+$ ]]; then
    RELEASE="${MAJOR}.${MINOR}.${POINT}-asm.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}-${REV}"
    KPT_BRANCH="${_CI_ASM_KPT_BRANCH:=$(version_message)}"
  else
    RELEASE="${MAJOR}.${MINOR}.${POINT}-asm.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}-${REV}"
    KPT_BRANCH="${_CI_ASM_KPT_BRANCH:=release-${MAJOR}.${MINOR}-asm}"
  fi
  RELEASE_LINE="${MAJOR}.${MINOR}."
  PREVIOUS_RELEASE_LINE="${MAJOR}.$(( MINOR - 1 ))."
  readonly RELEASE; readonly RELEASE_LINE; readonly PREVIOUS_RELEASE_LINE; readonly KPT_BRANCH;

  ISTIO_FOLDER_NAME="istio-${RELEASE}"; readonly ISTIO_FOLDER_NAME;
  ISTIOCTL_REL_PATH="${ISTIO_FOLDER_NAME}/bin/istioctl"; readonly ISTIOCTL_REL_PATH;
  BASE_REL_PATH="${ISTIO_FOLDER_NAME}/manifests/charts/base/files/gen-istio-cluster.yaml"; readonly BASE_REL_PATH;
  PACKAGE_DIRECTORY="asm/istio"; readonly PACKAGE_DIRECTORY;
  VALIDATION_FIX_SERVICE="${PACKAGE_DIRECTORY}/${VALIDATION_FIX_FILE_NAME}"; readonly VALIDATION_FIX_SERVICE;
  OPTIONS_DIRECTORY="${PACKAGE_DIRECTORY}/options"; readonly OPTIONS_DIRECTORY;
  OPERATOR_MANIFEST="${PACKAGE_DIRECTORY}/istio-operator.yaml"; readonly OPERATOR_MANIFEST;
  BETA_CRD_MANIFEST="${OPTIONS_DIRECTORY}/v1beta1-crds.yaml"; readonly BETA_CRD_MANIFEST;
  MANAGED_MANIFEST="${OPTIONS_DIRECTORY}/managed-control-plane.yaml"; readonly MANAGED_MANIFEST;
  MANAGED_WEBHOOKS="${OPTIONS_DIRECTORY}/managed-control-plane-webhooks.yaml"; readonly MANAGED_WEBHOOKS;
  EXPOSE_ISTIOD_SERVICE="${PACKAGE_DIRECTORY}/expansion/expose-istiod.yaml"; readonly EXPOSE_ISTIOD_SERVICE;
  CANONICAL_CONTROLLER_MANIFEST="asm/canonical-service/controller.yaml"; readonly CANONICAL_CONTROLLER_MANIFEST;

  AKUBECTL="$(which kubectl || true)"
  AGCLOUD="$(which gcloud || true)"
  AKPT="$(which kpt || true)"
}

### Convenience functions ###

#######
# run_command takes a list of arguments that represents a command
# If DRY_RUN or VERBOSE is enabled, it will print the command, and if DRY_RUN is
# not enabled it runs the command.
#######
run_command() {
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    warn "Would have executed: ${*}"
    return
  elif [[ "${VERBOSE}" -eq 0 ]]; then
    "${@}" 2>/dev/null
    return "$?"
  fi
  info "Running: '${*}'"
  info "-------------"
  local RETVAL
  { "${@}"; RETVAL="$?"; } || true
  return $RETVAL
}

apath() {
  "${APATH}" "${@}"
}

gcloud() {
  run_command "${AGCLOUD}" "${@}"
}

kubectl() {
  local KCF
  KCF="$(context_get-option "KUBECONFIG")"
  if [[ -z "${KCF}" ]]; then
    KCF="${KUBECONFIG}"
  fi
  run_command "${AKUBECTL}" --kubeconfig "${KCF}" "${@}"
}

kpt() {
  run_command "${AKPT}" "${@}"
}

istioctl() {
  run_command "$(istioctl_path)" "${@}"
}

istioctl_path() {
  if [[ -n "${_CI_ISTIOCTL_REL_PATH}" && -f "${_CI_ISTIOCTL_REL_PATH}" ]]; then
    echo "${_CI_ISTIOCTL_REL_PATH}"
  else
    echo "./${ISTIOCTL_REL_PATH}"
  fi
}


#######
# retry takes an integer N as the first argument, and a list of arguments
# representing a command afterwards. It will retry the given command up to N
# times before returning 1. If the command is kubectl, it will try to
# re-get credentials in case something caused the k8s IP to change.
#######
retry() {
  local MAX_TRIES; MAX_TRIES="${1}";
  shift 1
  for i in $(seq 0 "${MAX_TRIES}"); do
    if [[ "${i}" -eq "${MAX_TRIES}" ]]; then
      break
    fi
    { "${@}" && return 0; } || true
    warn "Failed, retrying...($((i+1)) of ${MAX_TRIES})"
    sleep 2
  done
  false
}

find_missing_strings() {
  local NEEDLES; NEEDLES="${1}";
  local HAYSTACK; HAYSTACK="${2}";
  local NOTFOUND; NOTFOUND="";

  while read -r needle; do
    EXITCODE=0
    grep -q "${needle}" <<EOF || EXITCODE=$?
${HAYSTACK}
EOF
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="${needle},${NOTFOUND}"
    fi
  done <<EOF
${NEEDLES}
EOF

  if [[ -n "${NOTFOUND}" ]]; then NOTFOUND="$(strip_trailing_commas "${NOTFOUND}")"; fi
  echo "${NOTFOUND}"
}

strip_trailing_commas() {
  # shellcheck disable=SC2001
  echo "${1}" | sed 's/,*$//g'
}

configure_kubectl(){
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    info "Fetching/writing GCP credentials to kubeconfig file..."
    KUBECONFIG="${KUBECONFIG}" retry 2 gcloud container clusters get-credentials "${CLUSTER_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${CLUSTER_LOCATION}"
    context_set-option "KUBECONFIG" "${KUBECONFIG}"
  else
    KUBECONFIG="$(context_get-option "KUBECONFIG")"
  fi

  if ! hash nc 2>/dev/null; then
     warn "nc not found, skipping k8s connection verification"
     warn "(Installation will continue normally.)"
     return
  fi

  info "Verifying connectivity (10s)..."
  local ADDR
  ADDR="$(kubectl config view --minify=true -ojson | \
    jq .clusters[0].cluster.server -r)"

  local RETVAL; RETVAL=0;
  run_command nc -zvw 10 "${ADDR:8:${#ADDR}}" 443 || RETVAL=$?
  if [[ "${RETVAL}" -ne 0 ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Couldn't connect to ${CLUSTER_NAME}.
If this is a private cluster, verify that the correct firewall rules are applied.
https://cloud.google.com/service-mesh/docs/gke-install-overview#requirements
EOF
  fi
  info "kubeconfig set to ${KUBECONFIG}"
  info "context set to $(kubectl config current-context)"
}

warn() {
  info "[WARNING]: ${1}" >&2
}

warn_pause() {
  warn "${1}"
  sleep 2
}

error() {
  info "[ERROR]: ${1}" >&2
}

info() {
  echo "${SCRIPT_NAME}: ${1}" >&2
}

fatal() {
  error "${1}"
  exit 2
}

fatal_with_usage() {
  error "${1}"
  usage_short >&2
  exit 2
}

starline() {
  echo "*****************************"
}

is_managed() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"

  if [[ "${MANAGED}" -ne 1 ]]; then false; fi
}

is_gcp() {
  true # hook for later
}

is_sa() {
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"

  if [[ -z "${SERVICE_ACCOUNT}" ]]; then false; fi
}

should_validate() {
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if [[ "${PRINT_CONFIG}" -eq 1 || "${_CI_NO_VALIDATE}" -eq 1 ]] || only_enable; then false; fi
}

only_enable() {
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  if [[ "${ONLY_ENABLE}" -eq 0 ]]; then false; fi
}

can_modify_at_all() {
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if [[ "${ONLY_VALIDATE}" -eq 1 || "${PRINT_CONFIG}" -eq 1 ]]; then false; fi
}

can_modify_cluster_roles() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_ROLES}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_cluster_labels() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_LABELS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_apis() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_iam_roles() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_IAM_ROLES}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_modify_gcp_components() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"

  if ! can_modify_at_all; then false; return; fi

  if is_managed || [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_register_cluster() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 && ("${USE_VM}" -eq 1 || "${USE_HUB_WIP}" -eq 1) ]] \
    || [[ "${ENABLE_REGISTRATION}" -eq 1 ]]; then
    true
  else
    false
  fi
}

can_create_namespace() {
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"

  if ! can_modify_at_all; then false; return; fi

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    true
  else
    false
  fi
}

needs_asm() {
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"

  if only_enable; then false; return; fi

  if [[ "${PRINT_CONFIG}" -eq 1 ]] || can_modify_at_all || should_validate; then
    true
  else
    false
  fi
}

enable_common_message() {
  echo "Alternatively, use --enable_all|-e to allow this tool to handle all dependencies."
}

version_message() {
  local VER; VER="${MAJOR}.${MINOR}.${POINT}-asm.${REV}+config${CONFIG_VER}";
  if [[ "${_CI_CRC_VERSION}" -eq 1 ]]; then
    VER="${VER}-$(crc32 "$0")"
  fi
  echo "${VER}"
}

### CLI/initial setup functions ###
usage_short() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} [OPTION]...

Set up, validate, and install ASM in a Google Cloud environment.
Use -h|--help with -v|--verbose to show detailed descriptions.

OPTIONS:
  -l|--cluster_location  <LOCATION>
  -n|--cluster_name      <NAME>
  -p|--project_id        <ID>
  --kc|--kubeconfig      <KUBECONFIG_FILE>
  --ctx|--context        <CONTEXT>
  -m|--mode              <MODE>
  -c|--ca                <CA>

  -o|--option            <FILE NAME>
  -s|--service_account   <ACCOUNT>
  -k|--key_file          <FILE PATH>
  -D|--output_dir        <DIR PATH>
  --co|--custom_overlay  <FILE NAME>

  --ca_cert              <FILE PATH>
  --ca_key               <FILE PATH>
  --root_cert            <FILE PATH>
  --cert_chain           <FILE PATH>
  --ca_name              <CA NAME>
  -r|--revision_name     <REVISION NAME>

FLAGS:
  -e|--enable_all
     --enable_cluster_roles
     --enable_cluster_labels
     --enable_gcp_apis
     --enable_gcp_iam_roles
     --enable_gcp_components
     --enable_registration
     --enable_namespace_creation

     --managed

     --print_config
     --disable_canonical_service
  -v|--verbose
     --dry_run
     --only_validate
     --only_enable
  -h|--help
  --version
EOF
}

usage() {
  cat << EOF
${SCRIPT_NAME} $(version_message)
usage: ${SCRIPT_NAME} [OPTION]...

Set up, validate, and install ASM in a Google Cloud environment.
Single argument options can also be passed via environment variables by using
the ALL_CAPS name. Options specified via flags take precedence over environment
variables.

OPTIONS:
  -l|--cluster_location  <LOCATION>   The GCP location of the target cluster.
  -n|--cluster_name      <NAME>       The name of the target cluster.
  -p|--project_id        <ID>         The GCP project ID.
  --kc|--kubeconfig      <KUBECONFIG> Path to the kubeconfig file to use for CLI requests.
                                      Required if not supplying --cluster_location,
                                      --cluster_name, --project_id in order to locate
                                      and connect to the intended cluster.
  --ctx|--context        <CONTEXT>    The name of the kubeconfig context to use.
  -m|--mode              <MODE>       The type of installation to perform.
                                      Passing --mode install will attempt a
                                      new ASM installation. Passing --mode
                                      migrate will attempt to migrate an Istio
                                      installation to ASM. Passing --mode
                                      upgrade will attempt to upgrade an
                                      existing ASM installation to a newer
                                      version. Allowed values for
                                      <MODE> are {install|migrate|upgrade}.
  -c|--ca                <CA>         The type of certificate authority to be
                                      used. Defaults to "mesh_ca" for --mode
                                      install. Specifying the CA is required
                                      for --mode migrate.  Allowed values for
                                      <CA> are {citadel|mesh_ca|gcp_cas}.
  -o|--option            <FILE NAME>  The name of a YAML file in the kpt pkg to
                                      apply. For options, see the
                                      anthos-service-mesh-package GitHub
                                      repo under GoogleCloudPlatform. Files
                                      should be in "asm/istio/options" folder,
                                      and shouldn't include the .yaml extension.
                                      (See https://git.io/JTDdi for options.)
                                      To add multiple files, specify them with
                                      multiple options one at a time.
  -s|--service_account   <ACCOUNT>    The name of a service account used to
                                      install ASM. If not specified, the gcloud
                                      user currently configured will be used.
  -k|--key_file          <FILE PATH>  The key file for a service account. This
                                      option can be omitted if not using a
                                      service account.
  -D|--output_dir        <DIR PATH>   The directory where this script will place
                                      downloaded ASM packages and configuration.
                                      If not specified, a temporary directory
                                      will be created. If specified and the
                                      directory already contains the necessary
                                      files, they will be used instead of
                                      downloading them again.
  --co|--custom_overlay  <FILE PATH>  The location of a YAML file to overlay on
                                      the ASM IstioOperator. This option can be
                                      omitted if not installing optional
                                      features. To add multiple files, specify
                                      them with multiple options one at a time.
  --ca_name              <CA NAME>    Required only if --ca option is gcp_cas.
                                      Name of the ca in the GCP CAS service used to
                                      sign certificates in the format
                                      'projects/project_name/locations/ \
                                      ca_region/certificateAuthorities/ca_name'.
  -r|--revision_name <REVISION NAME>  Custom revision label. Label needs to follow DNS
                                      label formats (re: RFC 1123). Not supported if
                                      control plane is managed. Prefixing the revision
                                      name with 'asm' is recommended.
  The following four options must be passed together and are only necessary
  for using a custom certificate for Citadel. Users that aren't sure whether
  they need this probably don't.

  --ca_cert              <FILE PATH>  The intermediate certificate
  --ca_key               <FILE PATH>  The key for the intermediate certificate
  --root_cert            <FILE PATH>  The root certificate
  --cert_chain           <FILE PATH>  The certificate chain

FLAGS:

  The following several flags all relate to allowing the script to create, set,
  or enable required APIs, roles, or services. These can all be performed
  manually before running the script if desired. To allow the script to perform
  every necessary action, pass the -e|--enable_all flag. All of these flags
  are incompatible with --only_validate.

  -e|--enable_all                     Allow the script to perform all of the
                                      individual enable actions below. (Environ
                                      registration won't happen unless necessary
                                      for a selected option.)
     --enable_cluster_roles           Allow the script to attempt to set
                                      the necessary cluster roles.
     --enable_cluster_labels          Allow the script to attempt to set
                                      necessary cluster labels.
     --enable_gcp_apis                Allow the script to enable GCP APIs on
                                      the user's behalf
     --enable_gcp_iam_roles           Allow the script to set the required GCP
                                      IAM permissions
     --enable_gcp_components          Allow the script to enable required GCP
                                      managed services and components
     --enable_registration            Allow the script to register the cluster
                                      to an environ
     --enable_namespace_creation      Allow the script to create the istio-system
                                      namespace for the user

     --managed                        Provision a remote, managed control plane
                                      instead of installing one in-cluster.

     --print_config                   Instead of installing ASM, print all of
                                      the compiled YAML to stdout. All other
                                      output will be written to stderr, even if
                                      it would normally go to stdout. Skip all
                                      validations and setup.
     --disable_canonical_service      Do not install the CanonicalService
                                      controller. This is required for ASM UI to
                                      support various features.
  -v|--verbose                        Print commands before and after execution.
     --dry_run                        Print commands, but don't execute them.
     --only_validate                  Run validation, but don't install.
     --only_enable                    Perform the specified steps to set up the
                                      current user/cluster but don't install
                                      anything.
  -h|--help                           Show this message and exit.
  --version                           Print the version of this tool and exit.

EXAMPLE:
The following invocation will install ASM to a cluster named "my_cluster" in
project "my_project" in region "us-central1-c" using the default "mesh_ca" as
the certificate authority:
  $> ${SCRIPT_NAME} \\
      -n my_cluster \\
      -p my_project \\
      -l us-central1-c \\
      -m install

  or

  $> ${SCRIPT_NAME} \\
      --kubeconfig kubeconfig_file \\
      --context kube context \\
      -m install
EOF
}

arg_required() {
  if [[ ! "${2:-}" || "${2:0:1}" = '-' ]]; then
    fatal "Option ${1} requires an argument."
  fi
}

parse_args() {
  if [[ "${*}" = '' ]]; then
    usage_short >&2
    exit 2
  fi

  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch

  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY=""
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY=""
  while [[ $# != 0 ]]; do
    case "${1}" in
      -l | --cluster_location | --cluster-location)
        arg_required "${@}"
        context_set-option "CLUSTER_LOCATION" "${2}"
        shift 2
        ;;
      -n | --cluster_name | --cluster-name)
        arg_required "${@}"
        context_set-option "CLUSTER_NAME" "${2}"
        shift 2
        ;;
      --kc | --kubeconfig)
        arg_required "${@}"
        context_set-option "KUBECONFIG" "${2}"
        KUBECONFIG_SUPPLIED=1
        shift 2
        ;;
      --ctx | --context)
        arg_required "${@}"
        context_set-option "CONTEXT" "${2}"
        shift 2
        ;;
      -p | --project_id | --project-id)
        arg_required "${@}"
        context_set-option "PROJECT_ID" "${2}"
        shift 2
        ;;
      -m | --mode)
        arg_required "${@}"
        context_set-option "MODE" "$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      -c | --ca)
        arg_required "${@}"
        context_set-option "CA" "$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
        shift 2
        ;;
      --ca_name | --ca-name)
        arg_required "${@}"
        context_set-option "CA_NAME" "${2}"
        shift 2
        ;;
      -o | --option)
        arg_required "${@}"
        OPTIONAL_OVERLAY="${2},${OPTIONAL_OVERLAY}"
        context_set-option "OPTIONAL_OVERLAY" "${OPTIONAL_OVERLAY}"
        if [[ "${2}" == "hub-meshca" ]]; then
          context_set-option "USE_HUB_WIP" 1
        fi
        if [[ "${2}" == "vm" ]]; then
          context_set-option "USE_VM" 1
        fi
        shift 2
        ;;
      --co | --custom_overlay | --custom-overlay)
        arg_required "${@}"
        CUSTOM_OVERLAY="${2},${CUSTOM_OVERLAY}"
        context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"
        shift 2
        ;;
      -e | --enable_all | --enable-all)
        context_set-option "ENABLE_ALL" 1
        shift 1
        ;;
      --enable_cluster_roles | --enable-cluster-roles)
        context_set-option "ENABLE_CLUSTER_ROLES" 1
        shift 1
        ;;
      --enable_cluster_labels | --enable-cluster-labels)
        context_set-option "ENABLE_CLUSTER_LABELS" 1
        shift 1
        ;;
      --enable_gcp_apis | --enable-gcp-apis)
        context_set-option "ENABLE_GCP_APIS" 1
        shift 1
        ;;
      --enable_gcp_iam_roles | --enable-gcp-iam-roles)
        context_set-option "ENABLE_GCP_IAM_ROLES" 1
        shift 1
        ;;
      --enable_gcp_components | --enable-gcp-components)
        context_set-option "ENABLE_GCP_COMPONENTS" 1
        shift 1
        ;;
      --enable_registration | --enable-registration)
        context_set-option "ENABLE_REGISTRATION" 1
        shift 1
        ;;
      --enable_namespace_creation | --enable-namespace-creation)
        context_set-option "ENABLE_NAMESPACE_CREATION" 1
        shift 1
        ;;
      --managed)
        context_set-option "MANAGED" 1
        REVISION_LABEL="asm-managed"
        shift 1
        ;;
      --disable_canonical_service | --disable-canonical-service)
        context_set-option "DISABLE_CANONICAL_SERVICE" 1
        shift 1
        ;;
      --print_config | --print-config)
        context_set-option "PRINT_CONFIG" 1
        shift 1
        ;;
      -s | --service_account | --service-account)
        arg_required "${@}"
        context_set-option "SERVICE_ACCOUNT" "${2}"
        shift 2
        ;;
      -k | --key_file | --key-file)
        arg_required "${@}"
        context_set-option "KEY_FILE" "${2}"
        shift 2
        ;;
      -D | --output_dir | --output-dir)
        arg_required "${@}"
        context_set-option "OUTPUT_DIR" "${2}"
        shift 2
        ;;
      --dry_run | --dry-run)
        context_set-option "DRY_RUN" 1
        shift 1
        ;;
      --only_validate | --only-validate)
        context_set-option "ONLY_VALIDATE" 1
        shift 1
        ;;
      --only_enable | --only-enable)
        context_set-option "ONLY_ENABLE" 1
        shift 1
        ;;
      --ca_cert | --ca-cert)
        arg_required "${@}"
        context_set-option "CA_CERT" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --ca_key | --ca-key)
        arg_required "${@}"
        context_set-option "CA_KEY" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --root_cert | --root-cert)
        arg_required "${@}"
        context_set-option "CA_ROOT" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      --cert_chain | --cert-chain)
        arg_required "${@}"
        context_set-option "CA_CHAIN" "${2}"
        context_set-option "CUSTOM_CA" 1
        shift 2
        ;;
      -r | --revision_name | --revision-name)
        arg_required "${@}"
        context_set-option "CUSTOM_REVISION" 1
        REVISION_LABEL="${2}"
        shift 2
        ;;
      -v | --verbose)
        context_set-option "VERBOSE" 1
        shift 1
        ;;
      -h | --help)
        context_set-option "PRINT_HELP" 1
        shift 1
        ;;
      --version)
        context_set-option "PRINT_VERSION" 1
        shift 1
        ;;
      *)
        fatal_with_usage "Unknown option ${1}"
        ;;
    esac
  done
  readonly REVISION_LABEL

  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  if [[ "${PRINT_HELP}" -eq 1 || "${PRINT_VERSION}" -eq 1 ]]; then
    if [[ "${PRINT_VERSION}" -eq 1 ]]; then
      version_message
    elif [[ "${VERBOSE}" -eq 1 ]]; then
      usage
    else
      usage_short
    fi
    exit
  fi

  # make sure to redirect stdout as soon as possible if we're dumping the config
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  if [[ "${PRINT_CONFIG}" -eq 1 ]]; then
    exec 3>&1
    exec 1>&2
  fi
}

validate_args() {
  ### Option variables ###
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local MODE; MODE="$(context_get-option "MODE")"
  local CA; CA="$(context_get-option "CA")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY="$(context_get-option "OPTIONAL_OVERLAY")"
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_CLUSTER_ROLES; ENABLE_CLUSTER_ROLES="$(context_get-option "ENABLE_CLUSTER_ROLES")"
  local ENABLE_CLUSTER_LABELS; ENABLE_CLUSTER_LABELS="$(context_get-option "ENABLE_CLUSTER_LABELS")"
  local ENABLE_GCP_APIS; ENABLE_GCP_APIS="$(context_get-option "ENABLE_GCP_APIS")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"
  local ENABLE_GCP_COMPONENTS; ENABLE_GCP_COMPONENTS="$(context_get-option "ENABLE_GCP_COMPONENTS")"
  local ENABLE_REGISTRATION; ENABLE_REGISTRATION="$(context_get-option "ENABLE_REGISTRATION")"
  local ENABLE_NAMESPACE_CREATION; ENABLE_NAMESPACE_CREATION="$(context_get-option "ENABLE_NAMESPACE_CREATION")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"
  local PRINT_CONFIG; PRINT_CONFIG="$(context_get-option "PRINT_CONFIG")"
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"
  local ONLY_VALIDATE; ONLY_VALIDATE="$(context_get-option "ONLY_VALIDATE")"
  local ONLY_ENABLE; ONLY_ENABLE="$(context_get-option "ONLY_ENABLE")"
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local MANAGED_SERVICE_ACCOUNT; MANAGED_SERVICE_ACCOUNT="$(context_get-option "MANAGED_SERVICE_ACCOUNT")"
  local PRINT_HELP; PRINT_HELP="$(context_get-option "PRINT_HELP")"
  local PRINT_VERSION; PRINT_VERSION="$(context_get-option "PRINT_VERSION")"
  local CUSTOM_CA; CUSTOM_CA="$(context_get-option "CUSTOM_CA")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local ENVIRON_PROJECT_ID; ENVIRON_PROJECT_ID="$(context_get-option "ENVIRON_PROJECT_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CUSTOM_REVISION; CUSTOM_REVISION="$(context_get-option "CUSTOM_REVISION")"
  local WI_ENABLED; WI_ENABLED="$(context_get-option "WI_ENABLED")"
  local CONTEXT; CONTEXT="$(context_get-option "CONTEXT")"
  local KUBECONFIG; KUBECONFIG="$(context_get-option "KUBECONFIG")"

  if [[ "${MODE}" == "install" && -z "${CA}" ]]; then
    CA="mesh_ca"
    context_set-option "CA" "${CA}"
  fi

  if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
    validate_revision_label
  fi

  if is_managed; then
    if [[ "${MODE}" != "install" ]]; then
      fatal "Migrate and upgrade are incompatible with managed control plane."
    fi

    if [[ "${CA}" == "citadel" ]]; then
      fatal "Citadel is not supported with managed control plane."
    fi

    if [[ "${CA}" == "gcp_cas" ]]; then
      fatal "Google Certificate Authority Service integration is not supported with managed control plane."
    fi

    if [[ "${CUSTOM_CA}" -eq 1 ]]; then
      fatal "Specifying a custom CA with managed control plane is not supported."
    fi

    if [[ "${USE_VM}" -eq 1 ]]; then
      fatal "Adding VM workloads with managed control plane is not supported."
    fi

    if [[ "${CUSTOM_REVISION}" -eq 1 ]]; then
      fatal "Specifying a revision label with managed control plane is not supported."
    fi

    if [[ -n "${CUSTOM_OVERLAY}" ]]; then
      fatal "Specifying a custom overlay file with managed control plane is not supported."
    fi
  fi

  local MISSING_ARGS=0
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      MISSING_ARGS=1
      warn "Missing value for ${REQUIRED_ARG}"
    fi
  done <<EOF
MODE
EOF

  local CLUSTER_DETAIL_SUPPLIED=0
  local CLUSTER_DETAIL_VALID=1
  while read -r REQUIRED_ARG; do
    if [[ -z "${!REQUIRED_ARG}" ]]; then
      CLUSTER_DETAIL_VALID=0
    else
      CLUSTER_DETAIL_SUPPLIED=1 # gke cluster param usage intended
    fi
  done <<EOF
PROJECT_ID
CLUSTER_LOCATION
CLUSTER_NAME
EOF

  # Script will not infer the intent between the 2 use cases in case both values are provided
  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    fatal_with_usage "Incompatible arguments. Kubeconfig cannot be used in conjuntion with [--cluster_location|--cluster_name|--project_id]."
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 1 && "${CLUSTER_DETAIL_VALID}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "Missing one or more required options for [CLUSTER_LOCATION|CLUSTER_NAME|PROJECT_ID]"
  fi

  if [[ "${CLUSTER_DETAIL_SUPPLIED}" -eq 0 && "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    MISSING_ARGS=1
    warn "At least one of the following is required: 1) --kubeconfig or 2) --cluster_location, --cluster_name, --project_id"
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 && -z "${CONTEXT}" ]]; then
    # set CONTEXT to current-context in the KUBECONFIG
    # or fail-fast if current-context doesn't exist
    CONTEXT="$(kubectl config current-context)"
    if [[ -z "${CONTEXT}" ]]; then
      MISSING_ARGS=1
      warn "Missing current-context in the KUBECONFIG. Please provide context with --context flag or set a current-context in the KUBECONFIG"
    else
      context_set-option "CONTEXT" "${CONTEXT}"
    fi
  fi

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 1 ]]; then
    info "Reading cluster information for ${CONTEXT}"
    IFS="_" read -r _ PROJECT_ID CLUSTER_LOCATION CLUSTER_NAME <<EOF
${CONTEXT}
EOF
    if is_gcp; then
      context_set-option "PROJECT_ID" "${PROJECT_ID}"
      context_set-option "CLUSTER_LOCATION" "${CLUSTER_LOCATION}"
      context_set-option "CLUSTER_NAME" "${CLUSTER_NAME}"
    fi
  fi

  if [[ "${MODE}" != "upgrade" ]]; then
    case "${CA}" in
      citadel | mesh_ca | gcp_cas);;
      "")
        MISSING_ARGS=1
        warn "Missing value for CA"
        ;;
      *) fatal "CA must be one of 'citadel', 'mesh_ca', 'gcp_cas'";;
    esac
  fi

  if [[ "${MISSING_ARGS}" -ne 0 ]]; then
    fatal_with_usage "Missing one or more required options."
  fi

  if [[ "${MODE}" == "upgrade" && -n "${CA}" ]]; then
    warn "The CA flag is ignored during an update operation."
    warn "Update will proceed with the currently installed CA."
  fi

  if [[ "${CA}" = "gcp_cas" ]]; then
    validate_gcp_cas_args
  fi

  # shellcheck disable=SC2064
  case "${MODE}" in
    install | migrate | upgrade);;
    *) fatal "MODE must be one of 'install', 'migrate', 'upgrade'";;
  esac

  if [[ "${MODE}" != "install" && "${USE_HUB_WIP}" -eq 1 ]]; then
    fatal "Hub Workload Identity Pool is only supported in new installation"
  fi
  if [[ "${CA}" == "citadel" && "${USE_HUB_WIP}" -eq 1 ]]; then
    fatal "Hub Workload Identity Pool is only supported for Mesh CA"
  fi

  if [[ "${USE_VM}" -eq 1 && "${USE_HUB_WIP}" -eq 0 ]]; then
    fatal "Hub Workload Identity Pool is required to add VM workloads. Run the script with the -o hub-meshca option."
  fi

  if [[ "${CUSTOM_CA}" -eq 1 ]]; then
    validate_certs
  fi

  while read -r FLAG; do
    if [[ "${!FLAG}" -ne 0 && "${!FLAG}" -ne 1 ]]; then
      fatal "${FLAG} must be 0 (off) or 1 (on) if set via environment variables."
    fi
    readonly "${FLAG}"
  done <<EOF
DRY_RUN
ENABLE_ALL
ENABLE_CLUSTER_ROLES
ENABLE_CLUSTER_LABELS
ENABLE_GCP_APIS
ENABLE_GCP_IAM_ROLES
ENABLE_GCP_COMPONENTS
ENABLE_REGISTRATION
MANAGED
DISABLE_CANONICAL_SERVICE
ONLY_VALIDATE
ONLY_ENABLE
VERBOSE
EOF

  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_CLUSTER_ROLES}" -eq 1 || \
    "${ENABLE_CLUSTER_LABELS}" -eq 1 || "${ENABLE_GCP_APIS}" -eq 1 || \
    "${ENABLE_GCP_IAM_ROLES}" -eq 1 || "${ENABLE_GCP_COMPONENTS}" -eq 1 || \
    "${ENABLE_REGISTRATION}" -eq 1  || "${ENABLE_NAMESPACE_CREATION}" -eq 1 ]]; then
    if [[ "${ONLY_VALIDATE}" -eq 1 ]]; then
      fatal "The only_validate flag cannot be used with any --enable* flag"
    fi
  elif only_enable; then
    fatal "You must specify at least one --enable* flag with --only_enable"
  fi

  if [[ -n "$SERVICE_ACCOUNT" && -z "$KEY_FILE" || -z "$SERVICE_ACCOUNT" && -n "$KEY_FILE" ]]; then
    fatal "Service account and key file must be used together."
  fi

  # since we cd to a tmp directory, we need the absolute path for the key file
  # and yaml file
  if [[ -f "${KEY_FILE}" ]]; then
    KEY_FILE="$(apath -f "${KEY_FILE}")"
    readonly KEY_FILE
  elif [[ -n "${KEY_FILE}" ]]; then
    fatal "Couldn't find key file ${KEY_FILE}."
  fi

  while read -d ',' -r yaml_file; do
    if [[ -f "${yaml_file}" ]]; then
      ABS_OVERLAYS="$(apath -f "${yaml_file}"),${ABS_OVERLAYS}"
    elif [[ -n "${yaml_file}" ]]; then
      fatal "Couldn't find yaml file ${yaml_file}."
    fi
  done <<EOF
${CUSTOM_OVERLAY}
EOF
  if [[ "${CA}" = "citadel" ]]; then
    ABS_OVERLAYS="${OPTIONS_DIRECTORY}/citadel-ca.yaml,${ABS_OVERLAYS}"
  elif [[ "${CA}" = "gcp_cas" ]]; then
    ABS_OVERLAYS="${OPTIONS_DIRECTORY}/private-ca.yaml,${ABS_OVERLAYS}"
  fi
  CUSTOM_OVERLAY="${ABS_OVERLAYS}"
  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"

  set_kpt_package_url
  WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"
}

validate_revision_label() {
  # Matches DNS label formats of RFC 1123
  local DNS_1123_LABEL_MAX_LEN; DNS_1123_LABEL_MAX_LEN=63;
  readonly DNS_1123_LABEL_MAX_LEN

  local DNS_1123_LABEL_FMT; DNS_1123_LABEL_FMT="^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?$";
  readonly DNS_1123_LABEL_FMT

  if [[ ${#REVISION_LABEL} -gt ${DNS_1123_LABEL_MAX_LEN} ]]; then
    fatal "Revision label cannot be longer than $DNS_1123_LABEL_MAX_LEN."
  fi

  if ! [[ "${REVISION_LABEL}" =~ ${DNS_1123_LABEL_FMT} ]]; then
    fatal "Revision label does not follow RFC 1123 formatting convention."
  fi
}

validate_gcp_cas_args() {
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local CA_NAME_TEMPLATE
  CA_NAME_TEMPLATE="projects/project_name/locations/ca_region/certificateAuthorities/ca_name"
  readonly CA_NAME_TEMPLATE

  if [[ -z ${CA_NAME} ]]; then
    fatal "A ca-name must be provided for integration with Google Certificate Authority Service."
  elif [[ $(grep -o "/" <<< "${CA_NAME}" | wc -l) != $(grep -o "/" <<< "${CA_NAME_TEMPLATE}" | wc -l) ]]; then
    fatal "Malformed ca-name. ca-name must be of the form ${CA_NAME_TEMPLATE}."
  elif [[ "$(echo "${CA_NAME}" | cut -f1 -d/)" != "$(echo "${CA_NAME_TEMPLATE}" | cut -f1 -d/)" ]]; then
    fatal "Malformed ca-name. ca-name must be of the form ${CA_NAME_TEMPLATE}."
  fi
}

validate_certs() {
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"

  if [[ "${CA}" != "citadel" ]]; then
    fatal "You must select Citadel as the CA in order to use custom certificates."
  fi
  if [[ -z "${CA_ROOT}" || -z "${CA_KEY}" || -z "${CA_CHAIN}" || -z "${CA_CERT}" ]]; then
    fatal "All four certificate options must be present to use a custom cert."
  fi
  while read -r CERT_FILE; do
    if ! [[ -f "${!CERT_FILE}" ]]; then
      fatal "Couldn't find file ${!CERT_FILE}."
    fi
  done <<EOF
CA_CERT
CA_ROOT
CA_KEY
CA_CHAIN
EOF

  CA_CERT="$(apath -f "${CA_CERT}")"; readonly CA_CERT;
  CA_KEY="$(apath -f "${CA_KEY}")"; readonly CA_KEY;
  CA_CHAIN="$(apath -f "${CA_CHAIN}")"; readonly CA_CHAIN;
  CA_ROOT="$(apath -f "${CA_ROOT}")"; readonly CA_ROOT;

  context_set-option "CA_CERT" "${CA_CERT}"
  context_set-option "CA_KEY" "${CA_KEY}"
  context_set-option "CA_CHAIN" "${CA_CHAIN}"
  context_set-option "CA_ROOT" "${CA_ROOT}"

  info "Checking certificate files for consistency..."
  if ! openssl rsa -in "${CA_KEY}" -check >/dev/null 2>/dev/null; then
    fatal "${CA_KEY} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_CERT}" -text -noout >/dev/null; then
    fatal "${CA_CERT} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_CHAIN}" -text -noout >/dev/null; then
    fatal "${CA_CHAIN} failed an openssl consistency check."
  fi
  if ! openssl x509 -in "${CA_ROOT}" -text -noout >/dev/null; then
    fatal "${CA_ROOT} failed an openssl consistency check."
  fi

  info "Checking key matches certificate..."
  local CERT_HASH; local KEY_HASH;
  CERT_HASH="$(openssl x509 -noout -modulus -in "${CA_CERT}" | openssl md5)";
  KEY_HASH="$(openssl rsa -noout -modulus -in "${CA_KEY}" | openssl md5)";
  if [[ "${CERT_HASH}" != "${KEY_HASH}" ]]; then
    fatal "Keyfile does not match the given certificate."
    fatal "Cert: ${CA_CERT}"
    fatal "Key: ${CA_KEY}"
  fi
  unset CERT_HASH; unset KEY_HASH;

  info "Verifying certificate chain of trust..."
  if ! openssl verify -trusted "${CA_ROOT}" -untrusted "${CA_CHAIN}" "${CA_CERT}"; then
    fatal "Unable to verify chain of trust."
  fi
}

set_kpt_package_url() {
  KPT_URL="https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages"
  KPT_URL="${KPT_URL}.git/asm@${KPT_BRANCH}"
  readonly KPT_URL;
}

auth_service_account() {
  local SERVICE_ACCOUNT; SERVICE_ACCOUNT="$(context_get-option "SERVICE_ACCOUNT")"
  local KEY_FILE; KEY_FILE="$(context_get-option "KEY_FILE")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Authorizing ${SERVICE_ACCOUNT} with ${KEY_FILE}..."
  gcloud auth activate-service-account \
    --project="${PROJECT_ID}" \
    "${SERVICE_ACCOUNT}" \
    --key-file="${KEY_FILE}"
}

#######
# set_up_local_workspace does everything that the script needs to avoid
# polluting the environment or current working directory
#######
set_up_local_workspace() {
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"
  info "Setting up necessary files..."
  if [[ -z "${OUTPUT_DIR}" ]]; then
    info "Creating temp directory..."
    OUTPUT_DIR="$(mktemp -d)"
    if [[ -z "${OUTPUT_DIR}" ]]; then
      fatal "Encountered error when running mktemp -d!"
    fi
    info ""
    info "$(starline)"
    info "No output folder was specified with --output_dir|-D, so configuration and"
    info "binaries will be stored in the following directory."
    info "${OUTPUT_DIR}"
    info "$(starline)"
    info ""
    sleep 2
  else
    OUTPUT_DIR="$(apath -f "${OUTPUT_DIR}")"
    if [[ ! -a "${OUTPUT_DIR}" ]]; then
      if ! mkdir -p "${OUTPUT_DIR}"; then
        fatal "Failed to create directory ${OUTPUT_DIR}"
      fi
    elif [[ ! -d "${OUTPUT_DIR}" ]]; then
      fatal "${OUTPUT_DIR} exists and is not a directory, please specify another directory."
    fi
  fi
  pushd "$OUTPUT_DIR" > /dev/null
  context_set-option "OUTPUT_DIR" "${OUTPUT_DIR}"

  # If KUBECONFIG file is supplied, keep using that.
  KUBECONFIG="$(context_get-option "KUBECONFIG")"

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    KUBECONFIG="asm_kubeconfig"
    context_set-option "KUBECONFIG" "${KUBECONFIG}"
  fi

  info "Using ${KUBECONFIG} as the kubeconfig..."
}

### Environment validation functions ###
validate_dependencies() {
  local MODE; MODE="$(context_get-option "MODE")"

  validate_node_pool
  validate_k8s
  validate_expected_control_plane

  if [[ "${MODE}" = "migrate" ]]; then
    validate_istio_version
  elif [[ "${MODE}" = "upgrade" ]]; then
    validate_asm_version
    validate_ca_consistency
  fi
}

organize_kpt_files() {
  local ABS_YAML
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  local OPTIONAL_OVERLAY; OPTIONAL_OVERLAY="$(context_get-option "OPTIONAL_OVERLAY")"

  while read -d ',' -r yaml_file; do
    ABS_YAML="${OPTIONS_DIRECTORY}/${yaml_file}.yaml"
    if [[ ! -f "${ABS_YAML}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Couldn't find yaml file ${yaml_file}.
See directory $(apath -f "${OPTIONS_DIRECTORY}") for available options.
EOF
    fi
    CUSTOM_OVERLAY="${ABS_YAML},${CUSTOM_OVERLAY}"
  done <<EOF
${OPTIONAL_OVERLAY}
EOF

  context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"
  context_set-option "OPTIONAL_OVERLAY" ""  # unset OPTIONAL_OVERLAY
}

# This is a workaround for https://github.com/istio/istio/issues/30632
# which doesn't handle files with multiple operator specs correctly.
# This will split all of the files based off of the yaml document separator.
handle_multi_yaml_bug() {
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"
  local CSPLIT_OUTPUT; CSPLIT_OUTPUT="";
  local BASE_NAME
  while read -d ',' -r yaml_file; do
    BASE_NAME="$(basename "${yaml_file}")"
    if [[ "$(csplit -f "overlay-${BASE_NAME}" "${yaml_file}" '/^---$/' '{*}' | wc -l)" -eq 1 ]]; then
      CSPLIT_OUTPUT="${CSPLIT_OUTPUT},${yaml_file}"
    else
      for split_file in overlay-"${BASE_NAME}"*; do
        if [[ -s "${split_file}" ]]; then
          CSPLIT_OUTPUT="${CSPLIT_OUTPUT},$(apath -f "${split_file}")"
        fi
      done
    fi
  done <<EOF
${CUSTOM_OVERLAY}
EOF
  if [[ -n "${CSPLIT_OUTPUT}" ]]; then
    CUSTOM_OVERLAY="${CSPLIT_OUTPUT:1:${#CSPLIT_OUTPUT}},"
    context_set-option "CUSTOM_OVERLAY" "${CUSTOM_OVERLAY}"
  fi
}

validate_cli_dependencies() {
  local NOTFOUND; NOTFOUND="";
  local EXITCODE; EXITCODE=0;
  local CUSTOM_CA; CUSTOM_CA="$(context_get-option "CUSTOM_CA")"

  info "Checking installation tool dependencies..."
  while read -r dependency; do
    EXITCODE=0
    hash "${dependency}" 2>/dev/null || EXITCODE=$?
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="${dependency},${NOTFOUND}"
    fi
  done <<EOF
awk
$AGCLOUD
grep
jq
$AKUBECTL
$AKPT
sed
tr
head
csplit
EOF

  while read -r FLAG; do
    if [[ -z "${!FLAG}" ]]; then
      NOTFOUND="${FLAG},${NOTFOUND}"
    fi
  done <<EOF
AKUBECTL
AGCLOUD
AKPT
EOF

  if [[ "${CUSTOM_CA}" -eq 1 ]]; then
    EXITCODE=0
    hash openssl 2>/dev/null || EXITCODE=$?
    if [[ "${EXITCODE}" -ne 0 ]]; then
      NOTFOUND="openssl,${NOTFOUND}"
    fi
  fi

  if [[ "${#NOTFOUND}" -gt 1 ]]; then
    NOTFOUND="$(strip_trailing_commas "${NOTFOUND}")"
    for dep in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "Dependency not found: ${dep}"
    done
    fatal "One or more dependencies were not found. Please install them and retry."
  fi

  local OS
  # shellcheck disable=SC2064
  trap "$(shopt -p nocasematch)" RETURN
  shopt -s nocasematch
  if [[ "$(uname -m)" != "x86_64" ]]; then
    fatal "Installation is only supported on x86_64."
  fi
}

download_asm() {
  local OS
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  case "$(uname)" in
    Linux ) OS="linux-amd64";;
    Darwin) OS="osx";;
    *     ) fatal "$(uname) is not a supported OS.";;
  esac

  info "Downloading ASM.."
  local TARBALL; TARBALL="istio-${RELEASE}-${OS}.tar.gz"
  if [[ -z "${_CI_ASM_PKG_LOCATION}" ]]; then
    curl -L "https://storage.googleapis.com/gke-release/asm/${TARBALL}" \
      | tar xz
  else
    local TOKEN; TOKEN="$(retry 2 gcloud --project="${PROJECT_ID}" auth print-access-token)"
    run_command curl -L "https://storage.googleapis.com/${_CI_ASM_PKG_LOCATION}/asm/${TARBALL}" \
      --header @- <<EOF | tar xz
Authorization: Bearer ${TOKEN}
EOF
  fi

  ln -s "${ISTIOCTL_REL_PATH}" .

  info "Downloading ASM kpt package..."
  retry 3 kpt pkg get --auto-set=false "${KPT_URL}" asm
  version_message > "${ASM_VERSION_FILE}"
}

necessary_files_exist() {
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"

  if [[ ! -f "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}" ]]; then
    false
    return
  elif [[ ! -f "${OUTPUT_DIR}/${OPERATOR_MANIFEST}" ]]; then
    false
    return
  fi

  # Refuse to overwrite configuration downloaded from a different version
  if [[ ! -f "${OUTPUT_DIR}/${ASM_VERSION_FILE}" ]]; then
    warn "Re-using existing configuration in ${OUTPUT_DIR}."
    warn_pause "If this was unintentional, please re-run with a different output directory."
    return
  fi

  local EXISTING_VER; EXISTING_VER="$(cat "${ASM_VERSION_FILE}")";
  if [[ "${EXISTING_VER}" != "$(version_message)" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
The existing configuration in ${OUTPUT_DIR} is from a different version.
Existing: ${EXISTING_VER}
Current: $(version_message)
Please try again and specify a different output directory.
EOF
  fi
}

validate_gcp_resources() {
  validate_cluster
}

populate_cluster_values() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  if [[ -z "${GKE_CLUSTER_URI}" && -z "${GCE_NETWORK_NAME}" ]]; then
    CLUSTER_DATA="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink, network)')"
    read -r GKE_CLUSTER_URI GCE_NETWORK_NAME <<EOF
${CLUSTER_DATA}
EOF

    GCE_NETWORK_NAME="${PROJECT_ID}-${GCE_NETWORK_NAME}"
    readonly GKE_CLUSTER_URI; readonly GCE_NETWORK_NAME;
  fi
}

get_project_number() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local RESULT; RESULT=""

  info "Checking for project ${PROJECT_ID}..."

  PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"

  if [[ -z "${PROJECT_NUMBER}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Unable to find project ${PROJECT_ID}. Please verify the spelling and try
again. To see a list of your projects, run:
  gcloud projects list --format='value(project_id)'
EOF
  fi

}

validate_cluster() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local RESULT; RESULT=""

  RESULT="$(gcloud container clusters list \
    --project="${PROJECT_ID}" \
    --filter="name = ${CLUSTER_NAME} AND location = ${CLUSTER_LOCATION}" \
    --format="value(name)" || true)"
  if [[ -z "${RESULT}" ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Unable to find cluster ${CLUSTER_LOCATION}/${CLUSTER_NAME}.
Please verify the spelling and try again. To see a list of your clusters, in
this project, run:
  gcloud container clusters list --format='value(name,zone)' --project="${PROJECT_ID}"
EOF
  fi
}

validate_k8s() {
  K8S_MINOR="$(kubectl version -o json | jq .serverVersion.minor | sed 's/[^0-9]//g')"
  if [[ "${K8S_MINOR}" -lt 15 ]]; then
    fatal "ASM ${RELEASE} requires Kubernetes version 1.15+, found 1.${K8S_MINOR}"
  fi
}

list_valid_pools() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  gcloud container node-pools list \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    --cluster "${CLUSTER_NAME}" \
    --filter "$(valid_pool_query "${1}")"\
    --format=json
}

#######
# valid_pool_query takes an integer argument: the minimum vCPU requirement.
# It outputs to stdout a query for `gcloud container node-pools list`
#######
valid_pool_query() {
  cat <<EOF | tr '\n' ' '
    config.machineType.split(sep="-").slice(-1:) >= $1
EOF
}

#######
# validate_node_pool makes sure that the cluster meets ASM's minimum compute
# requirements
#######
validate_node_pool() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local MACHINE_CPU_REQ; MACHINE_CPU_REQ=4; readonly MACHINE_CPU_REQ;
  local TOTAL_CPU_REQ; TOTAL_CPU_REQ=8; readonly TOTAL_CPU_REQ;

  info "Confirming node pool requirements for ${PROJECT_ID}/${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  local ACTUAL_CPU
  ACTUAL_CPU="$(list_valid_pools "${MACHINE_CPU_REQ}" | \
      jq '.[] |
        (if .autoscaling.enabled then .autoscaling.maxNodeCount else .initialNodeCount end)
        *
        (.config.machineType / "-" | .[-1] | try tonumber catch 1)
        * (.locations | length)
      ' 2>/dev/null)" || true

  local MAX_CPU; MAX_CPU=0;
  for i in ${ACTUAL_CPU}; do
    MAX_CPU="$(( i > MAX_CPU ? i : MAX_CPU))"
  done

  if [[ "$MAX_CPU" -lt "$TOTAL_CPU_REQ" ]]; then
    { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

ASM requires you to have at least ${TOTAL_CPU_REQ} vCPUs in node pools whose
machine type is at least ${MACHINE_CPU_REQ} vCPUs.
${CLUSTER_LOCATION}/${CLUSTER_NAME} does not meet this requirement. ASM
may not function as expected.

EOF
  fi
}

validate_expected_control_plane(){
  local MODE; MODE="$(context_get-option "MODE")"

  info "Checking Istio installations..."
  check_no_istiod_outside_of_istio_system_namespace
  if [[ "${MODE}" = "migrate" || "${MODE}" = "upgrade" ]]; then
    check_istio_deployed
  elif [[ "${MODE}" = "install" ]]; then
    check_istio_not_deployed
  fi
}

check_no_istiod_outside_of_istio_system_namespace() {
  local IN_ANY_NAMESPACE IN_NAMESPACE
  IN_ANY_NAMESPACE="$(kubectl get deployment -A --ignore-not-found=true | grep -c istiod || true)";
  IN_NAMESPACE="$(kubectl get deployment -n istio-system --ignore-not-found=true | grep -c istiod || true)";

  if [ "$IN_ANY_NAMESPACE" -gt "$IN_NAMESPACE" ]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
found istiod deployment outside of istio-system namespace. This installer
does not support that configuration.
EOF
  fi
}

get_istio_deployment_count(){
  local OUTPUT
  OUTPUT="$(retry 3 kubectl get deployment \
    -n istio-system \
    --ignore-not-found=true)"
  grep -c istiod <<EOF || true
$OUTPUT
EOF
}

check_istio_deployed(){
  local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
  local MODE; MODE="$(context_get-option "MODE")"

  info "Found ${ISTIOD_COUNT} deployment(s)."
  if [[ "$ISTIOD_COUNT" -eq 0 ]]; then
    warn_pause "${MODE} mode specified but no istiod deployment found. (Expected >=1.)"
  fi
}

check_istio_not_deployed(){
  local ISTIOD_COUNT; ISTIOD_COUNT="$(get_istio_deployment_count)";
  if [[ "$ISTIOD_COUNT" -ne 0 ]]; then
    { read -r -d '' MSG; warn_pause "${MSG}"; } <<EOF || true

Install mode specified, but ${ISTIOD_COUNT} existing istiod deployment(s) found. (Expected 0.)
Installation may overwrite existing control planes with the same revision.

EOF
  fi
}

validate_istio_version() {
  info "Checking existing Istio version(s)..."
  local VERSION_OUTPUT; VERSION_OUTPUT="$(retry 3 istioctl version -o json)"
  if [[ -z "${VERSION_OUTPUT}" ]]; then
    fatal "Couldn't validate existing Istio versions."
  fi
  local FOUND_VALID_VERSION; FOUND_VALID_VERSION=0
  for version in $(echo "${VERSION_OUTPUT}" | jq -r '.meshVersion[].Info.version' -r); do
    if [[ "$version" =~ ^$RELEASE_LINE || "$version" =~ ^$PREVIOUS_RELEASE_LINE ]]; then
      info "  $version (suitable for migration)"
      FOUND_VALID_VERSION=1
    else
      info "  $version (not suitable for migration)"
    fi
    if [[ "$version" =~ "asm" ]]; then
      fatal "Cannot migrate from version $version. Only migration from OSS Istio to the ASM distribution is supported."
    fi
  done
  if [[ "$FOUND_VALID_VERSION" -eq 0 ]]; then
    fatal "Migration requires an existing control plane in the ${RELEASE_LINE} line."
  fi
}

validate_asm_version() {
  info "Checking existing ASM version(s)..."
  local VERSION_OUTPUT; VERSION_OUTPUT="$(retry 3 istioctl version -o json)"
  if [[ -z "${VERSION_OUTPUT}" ]]; then
    fatal "Couldn't validate existing Istio versions."
  fi
  local FOUND_INVALID_VERSION; FOUND_INVALID_VERSION=0
  for VERSION in $(echo "${VERSION_OUTPUT}" | jq -r '.meshVersion[].Info.version'); do
    if ! [[ "${VERSION}" =~ "asm" ]]; then
      fatal "Cannot upgrade from version ${VERSION}. Only upgrades from ASM distributions are supported."
    fi

    if version_valid_for_upgrade "${VERSION}"; then
      info "  ${VERSION} (suitable for migration)"
    else
      info "  ${VERSION} (not suitable for migration)"
      FOUND_INVALID_VERSION=1
    fi
  done
  if [[ "$FOUND_INVALID_VERSION" -eq 1 ]]; then
    fatal "Upgrade requires all existing control planes to be between versions 1.$((MINOR-1)).0 (inclusive) and ${RELEASE} (exclusive)."
  fi
}

version_valid_for_upgrade() {
  local VERSION; VERSION=$1

  # if asm version found, pattern: 1.6.11-asm.1-586f900508ad482ed32b830dd15f6c54b32b93ed
  local VERSION_MAJOR VERSION_MINOR VERSION_POINT VERSION_REV
  IFS="." read -r VERSION_MAJOR VERSION_MINOR VERSION_POINT VERSION_REV <<EOF
${VERSION}
EOF
  VERSION_POINT="$(sed 's/-.*//' <<EOF
${VERSION_POINT}
EOF
)"
  VERSION_REV="$(sed 's/-.*//' <<EOF
${VERSION_REV}
EOF
)"
  if is_major_minor_invalid || is_minor_point_rev_invalid; then
    false
  fi
}

is_major_minor_invalid() {
  [[ "$VERSION_MAJOR" -ne 1 ]] && return 0
  [[ "$VERSION_MINOR" -lt $((MINOR-1))  ]] && return 0
  [[ "$VERSION_MINOR" -gt "$MINOR" ]] && return 0
}

is_minor_point_rev_invalid() {
  [[ "$VERSION_MINOR" -eq "$MINOR" ]] && is_point_rev_invalid && return 0
}

is_point_rev_invalid() {
  [[ "$VERSION_POINT" -gt "$POINT" ]] && return 0
  is_rev_invalid && return 0
}

is_rev_invalid() {
  [[ "$VERSION_POINT" -eq "$POINT" && "$VERSION_REV" -ge "$REV" ]] && return 0
}

validate_ca_consistency() {
  local CURRENT_CA; CURRENT_CA="citadel"
  local CA; CA="$(context_get-option "CA")"

  if is_meshca_installed; then
    CURRENT_CA="mesh_ca"
  elif is_gcp_cas_installed; then
    CURRENT_CA="gcp_cas"
  fi

  info "CA already in use: ${CURRENT_CA}"

  if [[ -z "${CA}" ]]; then
    CA="${CURRENT_CA}"
    context_set-option "CA" "${CA}"
  fi

  if [[ "${CA}" != "${CURRENT_CA}" ]]; then
    fatal "CA cannot be switched while performing upgrade. Please use ${CURRENT_CA} as the CA."
  fi
}

is_meshca_installed() {
  local INSTALLED_CA; INSTALLED_CA="$(kubectl -n istio-system get pod -l istio=ingressgateway \
    -o jsonpath='{.items[].spec.containers[].env[?(@.name=="CA_ADDR")].value}')"
  [[ "${INSTALLED_CA}" =~ meshca\.googleapis\.com ]] && return 0
}

is_gcp_cas_installed() {
  local INSTALLED_CA; INSTALLED_CA="$(kubectl -n istio-system get pod -l istio=istiod \
    -o jsonpath='{.items[].spec.containers[].env[?(@.name=="EXTERNAL_CA")].value}')"
  [[ "${INSTALLED_CA}" = "ISTIOD_RA_CAS_API" ]] && return 0
}

bind_user_to_iam_policy(){
  local ROLES; ROLES="${1}"
  local GCLOUD_MEMBER; GCLOUD_MEMBER="${2}"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Binding ${GCLOUD_MEMBER} to required IAM roles..."
  while read -r role; do
  retry 3 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member "${GCLOUD_MEMBER}" \
    --role="${role}" --condition=None >/dev/null
  done <<EOF
${ROLES}
EOF
}

exit_if_out_of_iam_policy() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local GCLOUD_MEMBER; GCLOUD_MEMBER="$(iam_user)";
  local MEMBER_ROLES
  MEMBER_ROLES="$(gcloud projects \
    get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:$(iam_user)" \
    --format='value(bindings.role)')"

  if [[ "${MEMBER_ROLES}" = *"roles/owner"* ]]; then
    return
  fi

  local REQUIRED; REQUIRED="$(required_iam_roles)";

  local NOTFOUND; NOTFOUND="$(find_missing_strings "${REQUIRED}" "${MEMBER_ROLES}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for role in $(echo "${NOTFOUND}" | tr ',' '\n'); do
      warn "IAM role not enabled - ${role}"
    done
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
One or more IAM roles required to install ASM is missing. Please add
${GCLOUD_MEMBER} to the roles above, or run
the script with "--enable_gcp_iam_roles" to allow the script to add
them on your behalf.
$(enable_common_message)
EOF
  fi
}

iam_user() {
  local MANAGED_SERVICE_ACCOUNT; MANAGED_SERVICE_ACCOUNT="$(context_get-option "MANAGED_SERVICE_ACCOUNT")"
  if ! is_managed; then
    local_iam_user
    return
  fi

  echo "serviceAccount:${MANAGED_SERVICE_ACCOUNT}"
}

local_iam_user() {
  if [[ -n "${GCLOUD_USER_OR_SA}" ]]; then
    echo "${GCLOUD_USER_OR_SA}"
    return
  fi

  info "Getting account information..."
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local ACCOUNT_NAME
  ACCOUNT_NAME="$(retry 3 gcloud auth list \
    --project="${PROJECT_ID}" \
    --filter="status:ACTIVE" \
    --format="value(account)")"
  if [[ -z "${ACCOUNT_NAME}" ]]; then
    fatal "Failed to get account name from gcloud. Please authorize and re-try installation."
  fi

  local ACCOUNT_TYPE
  ACCOUNT_TYPE="user"
  if is_sa || [[ "${ACCOUNT_NAME}" = *.iam.gserviceaccount.com ]]; then
    ACCOUNT_TYPE="serviceAccount"
  fi

  GCLOUD_USER_OR_SA="${ACCOUNT_TYPE}:${ACCOUNT_NAME}"

  echo "${GCLOUD_USER_OR_SA}"
}

required_iam_roles_mcp_sa() {
  cat <<EOF
roles/serviceusage.serviceUsageConsumer
roles/container.admin
roles/monitoring.metricWriter
roles/logging.logWriter
EOF
}

# [START required_iam_roles]
required_iam_roles() {
  # meshconfig.admin - required for init, stackdriver, UI elements, etc.
  # servicemanagement.admin/serviceusage.serviceUsageAdmin - enables APIs
  local CA; CA="$(context_get-option "CA")"
  if can_modify_gcp_components || \
     can_modify_cluster_labels || \
     can_modify_cluster_roles; then
    echo roles/container.admin
  fi
  if can_modify_gcp_components; then
    echo roles/meshconfig.admin
  fi
  if can_modify_gcp_apis; then
    echo roles/servicemanagement.admin
    echo roles/serviceusage.serviceUsageAdmin
  fi
  if can_modify_gcp_iam_roles; then
    echo roles/resourcemanager.projectIamAdmin
  fi
  if is_sa; then
    echo roles/iam.serviceAccountAdmin
  fi
  if can_register_cluster; then
    echo roles/gkehub.admin
  fi
  if [[ "${CA}" = "gcp_cas" ]]; then
    echo roles/privateca.admin
  fi
  if [[ "${_CI_I_AM_A_TEST_ROBOT}" -eq 1 ]]; then
    echo roles/compute.admin
    echo roles/iam.serviceAccountKeyAdmin
  fi
}
# [END required_iam_roles]

# [START required_apis]
required_apis() {
    local CA; CA="$(context_get-option "CA")"
    cat << EOF
container.googleapis.com
monitoring.googleapis.com
logging.googleapis.com
cloudtrace.googleapis.com
meshtelemetry.googleapis.com
meshconfig.googleapis.com
iamcredentials.googleapis.com
gkeconnect.googleapis.com
gkehub.googleapis.com
cloudresourcemanager.googleapis.com
stackdriver.googleapis.com
EOF
  case "${CA}" in
   mesh_ca)
     echo meshca.googleapis.com
     ;;
   gcp_cas)
     echo privateca.googleapis.com
     ;;
    *);;
  esac

  if [[ "${_CI_I_AM_A_TEST_ROBOT}" -eq 1 ]]; then
    echo compute.googleapis.com
  fi
}
# [END required_apis]

enable_gcloud_apis(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Enabling required APIs..."
  # shellcheck disable=SC2046
  retry 3 gcloud services enable --project="${PROJECT_ID}" $(required_apis | tr '\n' ' ')
}

get_enabled_apis() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local OUTPUT
  OUTPUT="$(retry 3 gcloud services list \
    --enabled \
    --format='get(config.name)' \
    --project="${PROJECT_ID}")"
  echo "${OUTPUT}" | tr '\n' ','
}

exit_if_apis_not_enabled() {
  local ENABLED; ENABLED="$(get_enabled_apis)";
  local REQUIRED; REQUIRED="$(required_apis)";
  local NOTFOUND; NOTFOUND="";

  info "Checking required APIs..."
  NOTFOUND="$(find_missing_strings "${REQUIRED}" "${ENABLED}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for api in $(echo "${NOTFOUND}" | tr ' ' '\n'); do
      warn "API not enabled - ${api}"
    done
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
One or more APIs are not enabled. Please enable them and retry, or run the
script with the '--enable_gcp_apis' flag to allow the script to enable them on
your behalf.
$(enable_common_message)
EOF
  fi
}

init_meshconfig() {
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local ENVIRON_PROJECT_ID; ENVIRON_PROJECT_ID="$(context_get-option "ENVIRON_PROJECT_ID")"
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig API..."
  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    populate_environ_info
    info "Cluster has Membership ID ${HUB_MEMBERSHIP_ID} in the Hub of project ${ENVIRON_PROJECT_ID}"
    if [[ "${ENVIRON_PROJECT_ID}" != "${PROJECT_ID}" ]]; then
      info "Skip initializing meshconfig API as the Hub is not hosted in the project ${PROJECT_ID}"
      return 0
    fi
    # initialize replaces the existing Workload Identity Pools in the IAM binding, so we need to support both Hub and GKE Workload Identity Pools
    local POST_DATA; POST_DATA='{"workloadIdentityPools":["'${ENVIRON_PROJECT_ID}'.hub.id.goog","'${ENVIRON_PROJECT_ID}'.svc.id.goog"]}'
    run_command curl --request POST --fail \
    --data "${POST_DATA}" -o /dev/null \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
  else
    run_command curl --request POST --fail \
    --data '' -o /dev/null \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    -K <(auth_header "$(get_auth_token)")
  fi
}

init_meshconfig_managed() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Initializing meshconfig managed API..."
  run_command curl --request POST --fail \
    --data '{"prepare_istiod": true}' \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
}

get_auth_token() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local TOKEN; TOKEN="$(retry 2 gcloud --project="${PROJECT_ID}" auth print-access-token)"
  echo "${TOKEN}"
}

# LTS releases don't have curl 7.55 so we can't use the @- construction,
# using -K keeps the token from printing if this script is run with -v
auth_header() {
  local TOKEN; TOKEN="${1}"
  echo "--header \"Authorization: Bearer ${TOKEN}\""
}

add_cluster_labels(){
  local LABELS; LABELS="$(get_cluster_labels)";

  local VERSION_TAG
  VERSION_TAG="${RELEASE//\./-}"
  local WANT; WANT="$(mesh_id_label; echo "asmv=${VERSION_TAG}")";

  local NOTFOUND; NOTFOUND="$(find_missing_strings "${WANT}" "${LABELS}")"

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  if [[ -z "${NOTFOUND}" ]]; then return 0; fi

  if [[ -n "${LABELS}" ]]; then
    LABELS="${LABELS},"
  fi
  LABELS="${LABELS}${NOTFOUND}"

  info "Adding labels to ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}" \
    --update-labels="${LABELS}"
}

exit_if_cluster_unlabeled() {
  local LABELS; LABELS="$(get_cluster_labels)";
  local REQUIRED; REQUIRED="$(mesh_id_label)";
  local NOTFOUND; NOTFOUND="$(find_missing_strings "${REQUIRED}" "${LABELS}")"

  if [[ -n "${NOTFOUND}" ]]; then
    for label in $(echo "${NOTFOUND}" | tr ',' '\n'); do
      warn "Cluster label not found - ${label}"
    done
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
One or more required cluster labels were not found. Please label them and retry,
or run the script with the '--enable_cluster_labels' flag to allow the script
to enable them on your behalf.
$(enable_common_message)
EOF
  fi
}

mesh_id_label() {
  echo "mesh_id=proj-${PROJECT_NUMBER}"
}

get_cluster_labels() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  info "Reading labels for ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  local LABELS
  LABELS="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
    --zone="${CLUSTER_LOCATION}" \
    --project="${PROJECT_ID}" \
    --format='value(resourceLabels)[delimiter=","]')";
  echo "${LABELS}"
}

is_cluster_registered() {
  if ! is_membership_crd_installed; then
    false
    return
  fi

  local IDENTITY_PROVIDER
  IDENTITY_PROVIDER="$(retry 2 kubectl get memberships.hub.gke.io \
    membership -ojson 2>/dev/null | jq .spec.identity_provider)"

  if [[ -z "${IDENTITY_PROVIDER}" ]] || [[ "${IDENTITY_PROVIDER}" == 'null' ]]; then
    false
  fi

  populate_environ_info
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local ENVIRON_PROJECT_ID; ENVIRON_PROJECT_ID="$(context_get-option "ENVIRON_PROJECT_ID")"

  local WANT
  WANT="//container.googleapis.com/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}"
  local LIST
  LIST="$(gcloud container hub memberships list --project "${ENVIRON_PROJECT_ID}" \
    --format=json | grep "${WANT}")"
  if [[ -z "${LIST}" ]]; then
    { read -r -d '' MSG; warn "${MSG}"; } <<EOF || true
Cluster is registered in the project ${ENVIRON_PROJECT_ID}, but the script is
unable to verify in the project. The script will continue to execute.
EOF
  fi
}

generate_membership_name() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local MEMBERSHIP_NAME
  MEMBERSHIP_NAME="${CLUSTER_NAME}"
  if [[ "$(retry 2 gcloud container hub memberships list --format='value(name)' \
   --project "${PROJECT_ID}" | grep -c "^${MEMBERSHIP_NAME}$" || true)" -ne 0 ]]; then
    MEMBERSHIP_NAME="${CLUSTER_NAME}-${PROJECT_ID}-${CLUSTER_LOCATION}"
  fi
  if [[ "${#MEMBERSHIP_NAME}" -gt 63 ]] || [[ "$(retry 2 gcloud container hub \
   memberships list --format='value(name)' --project "${PROJECT_ID}" | grep -c \
   "^${MEMBERSHIP_NAME}$" || true)" -ne 0 ]]; then
    local RAND
    RAND="$(tr -dc "a-z0-9" </dev/urandom | head -c8 || true)"
    MEMBERSHIP_NAME="${CLUSTER_NAME:0:54}-${RAND}"
  fi
  echo "${MEMBERSHIP_NAME}"
}

register_cluster() {
  if is_cluster_registered; then return; fi

  if can_modify_gcp_components; then
    enable_workload_identity
  else
    exit_if_no_workload_identity
  fi

  populate_cluster_values
  local MEMBERSHIP_NAME
  MEMBERSHIP_NAME="$(generate_membership_name)"
  info "Registering the cluster as ${MEMBERSHIP_NAME}..."

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  retry 2 gcloud beta container hub memberships register "${MEMBERSHIP_NAME}" \
    --project="${PROJECT_ID}" \
    --gke-uri="${GKE_CLUSTER_URI}" \
    --enable-workload-identity
}

exit_if_cluster_unregistered() {
  if ! is_cluster_registered; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cluster is not registered to an environ. Please register the cluster and
retry, or run the script with the '--enable_registration' flag to allow
the script to register to the current project's environ on your behalf.
EOF
  fi
}

is_workload_identity_enabled() {
  local WI_ENABLED; WI_ENABLED="$(context_get-option "WI_ENABLED")"
  if [[ "${WI_ENABLED}" -eq 1 ]]; then return; fi

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local ENABLED
  ENABLED="$(gcloud container clusters describe \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    "${CLUSTER_NAME}" \
    --format=json | \
    jq .workloadIdentityConfig)"

  if [[ "${ENABLED}" = 'null' ]]; then 
    false; 
  else 
    WI_ENABLED=1;
    context_set-option "WI_ENABLED" "${WI_ENABLED}"
  fi
}

is_membership_crd_installed() {
  if ! kubectl api-resources --api-group=hub.gke.io | grep -q memberships; then
    false
    return
  fi

  if [[ "$(retry 2 kubectl get memberships.hub.gke.io -ojsonpath="{..metadata.name}" \
    | grep -w -c membership || true)" -eq 0 ]]; then
    false
  fi
}

populate_environ_info() {
  local ENVIRON_PROJECT_ID; ENVIRON_PROJECT_ID="$(context_get-option "ENVIRON_PROJECT_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"

  if [[ -n "${ENVIRON_PROJECT_ID}" && -n "${HUB_MEMBERSHIP_ID}" ]]; then return; fi
  if ! is_membership_crd_installed; then return; fi
  HUB_MEMBERSHIP_ID="$(kubectl get memberships.hub.gke.io membership -o=json | jq .spec.owner.id | sed 's/^\"\/\/gkehub.googleapis.com\/projects\/\(.*\)\/locations\/global\/memberships\/\(.*\)\"$/\2/g')"
  context_set-option "HUB_MEMBERSHIP_ID" "${HUB_MEMBERSHIP_ID}"

  ENVIRON_PROJECT_ID="$(kubectl get memberships.hub.gke.io membership -o=json | jq .spec.workload_identity_pool | sed 's/^\"\(.*\).\(svc\|hub\).id.goog\"$/\1/g')"
  context_set-option "ENVIRON_PROJECT_ID" "${ENVIRON_PROJECT_ID}"
}

enable_workload_identity(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  if is_workload_identity_enabled; then return; fi
  info "Enabling Workload Identity on ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  info "(This could take awhile, up to 10 minutes)"
  retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}" \
    --workload-pool="${WORKLOAD_POOL}"
}

exit_if_no_workload_identity() {
  if ! is_workload_identity_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Workload identity is not enabled on ${CLUSTER_NAME}. Please enable it and
retry, or run the script with the '--enable_gcp_components' flag to allow
the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

is_stackdriver_enabled() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  local ENABLED
  ENABLED="$(gcloud container clusters describe \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    "${CLUSTER_NAME}" \
    --format=json | \
    jq '.
    | [
    select(
      .loggingService == "logging.googleapis.com/kubernetes"
      and .monitoringService == "monitoring.googleapis.com/kubernetes")
      ] | length')"

  if [[ "${ENABLED}" -lt 1 ]]; then false; fi
}

enable_stackdriver_kubernetes(){
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"

  info "Enabling Stackdriver on ${CLUSTER_LOCATION}/${CLUSTER_NAME}..."
  retry 2 gcloud container clusters update "${CLUSTER_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${CLUSTER_LOCATION}" \
    --enable-stackdriver-kubernetes
}

exit_if_stackdriver_not_enabled() {
  if ! is_stackdriver_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Cloud Operations (Stackdriver)  is not enabled on ${CLUSTER_NAME}.
Please enable it and retry, or run the script with the
'--enable_gcp_components' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

is_user_cluster_admin() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local GCLOUD_USER; GCLOUD_USER="$(gcloud config get-value core/account)"
  local IAM_USER; IAM_USER="$(local_iam_user)"
  local ROLES
  ROLES="$(\
    kubectl get clusterrolebinding \
    --all-namespaces \
    -o jsonpath='{range .items[?(@.subjects[0].name=="'"${GCLOUD_USER}"'")]}[{.roleRef.name}]{end}'\
    2>/dev/null)"
  if echo "${ROLES}" | grep -q cluster-admin; then return; fi

  ROLES="$(gcloud projects \
    get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members' \
    --filter="bindings.members:${IAM_USER}" \
    --format='value(bindings.role)' 2>/dev/null)"
  if echo "${ROLES}" | grep -q roles/container.admin; then return; fi

  false
}

bind_user_to_cluster_admin(){
  info "Querying for core/account..."
  local GCLOUD_USER; GCLOUD_USER="$(gcloud config get-value core/account)"
  info "Binding ${GCLOUD_USER} to cluster admin role..."
  local PREFIX; PREFIX="$(echo "${GCLOUD_USER}" | cut -f 1 -d @)"
  local YAML; YAML="$(retry 5 kubectl create \
    clusterrolebinding "${PREFIX}-cluster-admin-binding" \
    --clusterrole=cluster-admin \
    --user="${GCLOUD_USER}" \
    --dry-run -o yaml)"
  retry 3 kubectl apply -f - <<EOF
${YAML}
EOF
}

exit_if_not_cluster_admin() {
  if ! is_user_cluster_admin; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Current user must have the cluster-admin role on ${CLUSTER_NAME}.
Please add the cluster role binding and retry, or run the script with the
'--enable_cluster_roles' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

create_istio_namespace() {
  info "Creating istio-system namespace..."

  if istio_namespace_exists; then return; fi
  
  retry 2 kubectl create ns istio-system
}

exit_if_istio_namespace_not_exists() {
  info "Checking for istio-system namespace..."
  if ! istio_namespace_exists; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
The istio-system namespace doesn't exist.
Please create the "istio-namespace" and retry, or run the script with the
'--enable_namespace_creation' flag to allow the script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

istio_namespace_exists() {
  if [[ "${NAMESPACE_EXISTS}" -eq 1 ]]; then return; fi
  if [[ "$(retry 2 kubectl get ns | grep -c istio-system || true)" -eq 0 ]]; then
    false
  else
    NAMESPACE_EXISTS=1
  fi
}

register_gce_identity_provider() {
  info "Registering GCE Identity Provider in the cluster..."
  retry 3 kubectl apply -f asm/identity-provider/identityprovider-crd.yaml
  retry 3 kubectl apply -f asm/identity-provider/googleidp.yaml
}

should_enable_service_mesh_feature() {
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"

  if [[ "${USE_VM}" -eq 0 ]]; then
    false
  fi
}

enable_service_mesh_feature() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  info "Enabling the service mesh feature..."

  # IAM permission: gkehub.features.create
  retry 2 run_command curl -s -H "Content-Type: application/json" \
    -XPOST "https://gkehub.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/global/features?feature_id=servicemesh"\
    -d '{servicemesh_feature_spec: {}}' \
    -K <(auth_header "$(get_auth_token)")
}

exit_if_service_mesh_feature_not_enabled() {
  if ! is_service_mesh_feature_enabled; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
The service mesh feature is not enabled on project ${PROJECT_ID}.
Please run the script with the '--enable_gcp_components' flag to allow the
script to enable it on your behalf.
$(enable_common_message)
EOF
  fi
}

is_service_mesh_feature_enabled() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"

  local RESPONSE
  # IAM permission: gkehub.features.get
  RESPONSE="$(run_command curl -s -H "X-Goog-User-Project: ${PROJECT_ID}"  \
    "https://gkehub.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/global/features/servicemesh" \
    -K <(auth_header "$(get_auth_token)"))"

  if [[ "$(echo "${RESPONSE}" | jq -r '.featureState.lifecycleState')" != "ENABLED" ]]; then
    false
  fi
}

### Installation functions ###
configure_package() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local USE_HUB_WIP; USE_HUB_WIP="$(context_get-option "USE_HUB_WIP")"
  local ENVIRON_PROJECT_ID; ENVIRON_PROJECT_ID="$(context_get-option "ENVIRON_PROJECT_ID")"
  local HUB_MEMBERSHIP_ID; HUB_MEMBERSHIP_ID="$(context_get-option "HUB_MEMBERSHIP_ID")"
  local CA; CA="$(context_get-option "CA")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"

  info "Configuring kpt package..."

  populate_cluster_values
  populate_environ_info
  kpt cfg set asm gcloud.container.cluster "${CLUSTER_NAME}"
  kpt cfg set asm gcloud.core.project "${PROJECT_ID}"
  kpt cfg set asm gcloud.project.environProjectNumber "${PROJECT_NUMBER}"
  if [[ -n "${_CI_ENVIRON_PROJECT_NUMBER}" ]]; then
    kpt cfg set asm gcloud.project.environProjectNumber "${_CI_ENVIRON_PROJECT_NUMBER}"
  fi
  kpt cfg set asm gcloud.compute.location "${CLUSTER_LOCATION}"
  kpt cfg set asm gcloud.compute.network "${GCE_NETWORK_NAME}"
  kpt cfg set asm anthos.servicemesh.rev "${REVISION_LABEL}"
  kpt cfg set asm anthos.servicemesh.tag "${RELEASE}"
  if [[ -n "${_CI_ASM_IMAGE_LOCATION}" ]]; then
    kpt cfg set asm anthos.servicemesh.hub "${_CI_ASM_IMAGE_LOCATION}"
  fi
  if [[ -n "${_CI_ASM_IMAGE_TAG}" ]]; then
    kpt cfg set asm anthos.servicemesh.tag "${_CI_ASM_IMAGE_TAG}"
  fi

  if [[ "${USE_HUB_WIP}" -eq 1 ]]; then
    kpt cfg set asm gcloud.project.environProjectID "${ENVIRON_PROJECT_ID}"
    kpt cfg set asm anthos.servicemesh.hubMembershipID "${HUB_MEMBERSHIP_ID}"
  fi
  if [[ -n "${CA_NAME}" && "${CA}" = "gcp_cas" ]]; then
    kpt cfg set asm anthos.servicemesh.external_ca.ca_name "${CA_NAME}"
  fi

  if [[ "${USE_VM}" -eq 1 ]] && [[ "${_CI_NO_REVISION}" -eq 0 ]]; then
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod-${REVISION_LABEL}.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod-${REVISION_LABEL}.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs-${REVISION_LABEL}"
  fi

  if [[ "${CA}" == "mesh_ca" && -n "${_CI_TRUSTED_GCP_PROJECTS}" ]]; then
    # Gather the trust domain aliases from projects.
    TRUST_DOMAIN_ALIASES="${PROJECT_ID}.svc.id.goog"
    while IFS=',' read -r trusted_gcp_project; do
      TRUST_DOMAIN_ALIASES="${TRUST_DOMAIN_ALIASES} ${trusted_gcp_project}.svc.id.goog"
    done <<EOF
${_CI_TRUSTED_GCP_PROJECTS}
EOF
    # kpt treats words in quotes as a single param, while kpt need ${TRUST_DOMAIN_ALIASES} to be splitting params for a list. If we remove quotes, the lint will complain.
    # eval will translate the quoted TRUST_DOMAIN_ALIASES into params to workaround both.
    run_command eval kpt cfg set asm anthos.servicemesh.trustDomainAliases "${TRUST_DOMAIN_ALIASES}"
  fi

  if [[ "${MANAGED}" -eq 1 ]]; then
    local VALIDATION_URL; local CLOUDRUN_ADDR;
    read -r VALIDATION_URL CLOUDRUN_ADDR <<EOF
$(scrape_managed_urls)
EOF

    kpt cfg set asm anthos.servicemesh.controlplane.validation-url "${VALIDATION_URL}"
    kpt cfg set asm anthos.servicemesh.managed-controlplane.cloudrun-addr "${CLOUDRUN_ADDR}"
  fi
}

print_config() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"

  if [[ "${MANAGED}" -eq 1 ]]; then
    cat "${MANAGED_MANIFEST}"
    return
  fi

  PARAMS="-f ${OPERATOR_MANIFEST}"
  while read -d ',' -r yaml_file; do
    PARAMS="${PARAMS} -f ${yaml_file} "
  done <<EOF
${CUSTOM_OVERLAY}
EOF
  # shellcheck disable=SC2086
  istioctl profile dump ${PARAMS}
}

install_secrets() {
  local CA_CERT; CA_CERT="$(context_get-option "CA_CERT")"
  local CA_KEY; CA_KEY="$(context_get-option "CA_KEY")"
  local CA_ROOT; CA_ROOT="$(context_get-option "CA_ROOT")"
  local CA_CHAIN; CA_CHAIN="$(context_get-option "CA_CHAIN")"

  info "Installing certificates into the cluster..."
  kubectl create secret generic cacerts -n istio-system \
    --from-file="${CA_CERT}" \
    --from-file="${CA_KEY}" \
    --from-file="${CA_ROOT}" \
    --from-file="${CA_CHAIN}"
}

init_gcp_cas() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local WORKLOAD_IDENTITY; WORKLOAD_IDENTITY="$PROJECT_ID.svc.id.goog[istio-system/istiod-service-account]"

  local NAME; NAME=$(echo "${CA_NAME}" | cut -f6 -d/)
  local CA_LOCATION; CA_LOCATION=$(echo "${CA_NAME}" | cut -f4 -d/)
  local CA_PROJECT; CA_PROJECT=$(echo "${CA_NAME}" | cut -f2 -d/)

  retry 3 gcloud beta privateca subordinates add-iam-policy-binding "${NAME}" \
    --location "${CA_LOCATION}" \
    --project "${CA_PROJECT}" \
    --member "serviceAccount:${WORKLOAD_IDENTITY}" \
    --role "roles/privateca.certificateManager"
}

does_istiod_exist(){
  local RETVAL; RETVAL=0;
  kubectl get service \
    --request-timeout='20s' \
    -n istio-system \
    istiod 1>/dev/null 2>/dev/null || RETVAL=$?
  return "${RETVAL}"
}

install_asm() {
  local MODE; MODE="$(context_get-option "MODE")"
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"
  local USE_VM; USE_VM="$(context_get-option "USE_VM")"
  local CUSTOM_OVERLAY; CUSTOM_OVERLAY="$(context_get-option "CUSTOM_OVERLAY")"

  if ! does_istiod_exist && [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    info "Installing validation webhook fix..."
    retry 3 kubectl apply -f "${VALIDATION_FIX_SERVICE}"
  elif [[ "${MODE}" == "upgrade" ]]; then
    cp "${VALIDATION_FIX_SERVICE}" .
  fi

  local PARAMS
  PARAMS="-f ${OPERATOR_MANIFEST}"
  while read -d ',' -r yaml_file; do
    PARAMS="${PARAMS} -f ${yaml_file}"
  done <<EOF
${CUSTOM_OVERLAY}
EOF

  if [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    PARAMS="${PARAMS} --set revision=${REVISION_LABEL}"
  fi

  if [[ "${K8S_MINOR}" -eq 15 ]]; then
    PARAMS="${PARAMS} -f ${BETA_CRD_MANIFEST}"
  fi
  PARAMS="${PARAMS} -c ${KUBECONFIG}"
  PARAMS="${PARAMS} --skip-confirmation"

  info "Installing ASM control plane..."
  # shellcheck disable=SC2086
  retry 5 istioctl install $PARAMS

  # Prevent the stderr buffer from ^ messing up the terminal output below
  sleep 1
  info "...done!"

  local RAW_YAML; RAW_YAML="${REVISION_LABEL}-manifest-raw.yaml"
  local EXPANDED_YAML; EXPANDED_YAML="${REVISION_LABEL}-manifest-expanded.yaml"
  print_config >| "${RAW_YAML}"
  istioctl manifest generate \
    <"${RAW_YAML}" \
    >|"${EXPANDED_YAML}"

  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi

  if [[ "${USE_VM}" -eq 1 ]]; then
    info "Exposing the control plane for VM workloads..."
    expose_istiod

    # The default istiod service is exposed so that any fallback on the VM side
    # to use the default Istiod service can still connect to the control plane.
    kpt cfg set asm anthos.servicemesh.istiodHost "istiod.istio-system.svc"
    kpt cfg set asm anthos.servicemesh.istiodHostFQDN "istiod.istio-system.svc.cluster.local"
    kpt cfg set asm anthos.servicemesh.istiod-vs-name "istiod-vs"
    expose_istiod
  fi

  outro
}

install_canonical_controller() {
  info "Installing ASM CanonicalService controller in asm-system namespace..."
  retry 3 kubectl apply -f "${CANONICAL_CONTROLLER_MANIFEST}"
  info "Waiting for deployment..."
  retry 3 kubectl wait --for=condition=available --timeout=600s \
      deployment/canonical-service-controller-manager -n asm-system
  info "...done!"
}

expose_istiod() {
  retry 3 kubectl apply -f "${EXPOSE_ISTIOD_SERVICE}"
}

start_managed_control_plane() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"

  local CR_IMAGE_JSON; CR_IMAGE_JSON="";
  if [[ -n "${_CI_CLOUDRUN_IMAGE_HUB}" ]]; then
    CR_IMAGE_JSON=$(cat <<EOF
{"image": "${_CI_CLOUDRUN_IMAGE_HUB}:${_CI_CLOUDRUN_IMAGE_TAG}"}
EOF
)
  fi
  retry 2 run_command curl --request POST \
    "https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${CLUSTER_LOCATION}/clusters/${CLUSTER_NAME}:runIstiod" \
    --data "${CR_IMAGE_JSON}" \
    --header "X-Server-Timeout: 600" \
    --header "Content-Type: application/json" \
    -K <(auth_header "$(get_auth_token)")
}

scrape_managed_urls() {
  local URL
  URL="$(kubectl get mutatingwebhookconfiguration istiod-asm-managed -ojson | jq .webhooks[0].clientConfig.url -r)"
  # shellcheck disable=SC2001
  VALIDATION_URL="$(echo "${URL}" | sed 's/inject.*$/validate/g')"
  # shellcheck disable=SC2001
  CLOUDRUN_ADDR=$(echo "${URL}" | cut -d'/' -f3)

  echo "${VALIDATION_URL} ${CLOUDRUN_ADDR}"
}

install_managed_components() {
  local DISABLE_CANONICAL_SERVICE; DISABLE_CANONICAL_SERVICE="$(context_get-option "DISABLE_CANONICAL_SERVICE")"

  info "Configuring base installation for managed control plane..."
  kubectl apply --overwrite=true -f "${BASE_REL_PATH}"

  info "Configuring ASM managed control plane validating webhook config..."
  kubectl apply -f "${MANAGED_WEBHOOKS}"

  info "Configuring ASM managed control plane components..."
  print_config >| managed_control_plane_gateway.yaml


  if [[ "$DISABLE_CANONICAL_SERVICE" -eq 0 ]]; then
    install_canonical_controller
  fi
}

outro() {
  local MODE; MODE="$(context_get-option "MODE")"
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"

  info ""
  info "$(starline)"
  istioctl version
  info "$(starline)"
  info "The ASM control plane installation is now complete."
  info "To enable automatic sidecar injection on a namespace, you can use the following command:"
  info "kubectl label namespace <NAMESPACE> istio-injection- istio.io/rev=${REVISION_LABEL} --overwrite"
  info "If you use 'istioctl install' afterwards to modify this installation, you will need"
  info "to specify the option '--set revision=${REVISION_LABEL}' to target this control plane"
  info "instead of installing a new one."


  if [[ "${MODE}" = "migrate" || "${MODE}" = "upgrade" ]]; then
    info "Please verify the new control plane and then: 1) migrate your workloads 2) remove old control plane."
    info "For more information, see:"
    info "https://cloud.google.com/service-mesh/docs/upgrading-gke#redeploying_workloads"
    info "Before removing the old control plane, update the service used by validation if necessary."
    info "If the 'istiod' service has a revision label different than ${REVISION_LABEL}, then apply"
    info "${OUTPUT_DIR}/${VALIDATION_FIX_FILE_NAME} using 'kubectl apply'"
  elif [[ "${MODE}" = "install" ]]; then
    info "To finish the installation, enable Istio sidecar injection and restart your workloads."
    info "For more information, see:"
    info "https://cloud.google.com/service-mesh/docs/proxy-injection"
  fi
  info "The ASM package used for installation can be found at:"
  info "${OUTPUT_DIR}/asm"
  info "The version of istioctl that matches the installation can be found at:"
  info "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}"
  info "A symlink to the istioctl binary can be found at:"
  info "${OUTPUT_DIR}/istioctl"
  if ! is_managed; then
    info "The combined configuration generated for installation can be found at:"
    info "${OUTPUT_DIR}/${RAW_YAML}"
    info "The full, expanded set of kubernetes resources can be found at:"
    info "${OUTPUT_DIR}/${EXPANDED_YAML}"
  else
    info "You can find the gateway config to install with istioctl here:"
    info "${OUTPUT_DIR}/managed_control_plane_gateway.yaml"
  fi

  info "$(starline)"
}
