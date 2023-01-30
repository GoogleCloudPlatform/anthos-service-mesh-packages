KUBE_TAG_MAX_LEN=63; readonly KUBE_TAG_MAX_LEN

gen_install_params() {
  local CA; CA="$(context_get-option "CA")"

  local PARAM_BUILDER="-f ${OPERATOR_MANIFEST}"
  for yaml_file in $(context_list "istioctlFiles"); do
    PARAM_BUILDER="${PARAM_BUILDER} -f ${yaml_file}"
  done

  if [[ "${K8S_MINOR}" -eq 15 ]]; then
    PARAM_BUILDER="${PARAM_BUILDER} -f ${BETA_CRD_MANIFEST}"
  fi

  if [[ "${CA}" == "citadel" ]]; then
    PARAM_BUILDER="${PARAM_BUILDER} -f ${CITADEL_MANIFEST}"
  fi

  echo "${PARAM_BUILDER}"
}

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
  local CMD="'$*'"
  warn "Command $CMD failed."
  false
}

find_missing_strings() {
  local NEEDLES; NEEDLES="${1}";
  local HAYSTACK; HAYSTACK="${2}";
  local NOTFOUND; NOTFOUND="";
  local EXITCODE; EXITCODE=0;

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
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  if hash ts 2>/dev/null && [[ "${VERBOSE}" -eq 1 ]]; then
    echo "${SCRIPT_NAME}: ${1}" | TZ=utc ts '%Y-%m-%dT%.T' >&2
  else
    echo "${SCRIPT_NAME}: ${1}" >&2
  fi
}

validation_error() {
  error "${1}"
  if only_validate; then
    local VALIDATION_ERROR; VALIDATION_ERROR="$(context_get-option "VALIDATION_ERROR")"
    context_set-option "VALIDATION_ERROR" $((VALIDATION_ERROR + 1))
  else
    exit 2
  fi
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

prompt_user_for_value() {
  read -r -p "Please provide a value for ${1}:" VALUE
  if [[ -n "${VALUE}" ]]; then
    echo "${VALUE}"
  fi
}

prompt_default_no() {
  read -r -p "${1} [y/N] " response
  case "$response" in
      [yY][eE][sS]|[yY])
          return
          ;;
  esac
  false
}

starline() {
  echo "*****************************"
}

enable_common_message() {
  echo "Alternatively, use --enable_all|-e to allow this tool to handle all dependencies."
}

download_kpt() {
  local PLATFORM HTTPS_PROXY
  PLATFORM="$(get_platform "$(uname)" "$(uname -m)")"
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"

  if [[ -z "${PLATFORM}" ]]; then
    fatal "$(uname) $(uname -m) is not a supported platform to perform installation from."
  fi

  local KPT_TGZ
  KPT_TGZ="https://github.com/GoogleContainerTools/kpt/releases/download/v0.39.3/kpt_${PLATFORM}-0.39.3.tar.gz"

  info "Downloading kpt.."
  if [[ -n "${HTTPS_PROXY}" ]]; then
    HTTPS_PROXY="${HTTPS_PROXY}" curl -L "${KPT_TGZ}" | tar xz
  else
    curl -L "${KPT_TGZ}" | tar xz
  fi
  AKPT="$(apath -f kpt)"
}

get_platform() {
  local OS; OS="${1}"
  local ARCH; ARCH="${2}"
  local PLATFORM

  case "${OS}" in
    Linux ) PLATFORM="linux_amd64";;
    Darwin)
      if [[ "${ARCH}" == "arm64" ]]; then
        PLATFORM="darwin_arm64"
      else
        PLATFORM="darwin_amd64"
      fi
    ;;
  esac

  echo "${PLATFORM}"
}

download_asm() {
  local OS HTTPS_PROXY
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"

  case "$(uname)" in
    Linux ) OS="linux-amd64";;
    Darwin)
      OS="osx"
      if [[ "$(uname -a)" = "arm64" ]]; then OS="${OS}-arm64"; fi
    ;;
    *     ) fatal "$(uname) is not a supported OS.";;
  esac

  info "Downloading ASM.."
  local TARBALL; TARBALL="istio-${RELEASE}-${OS}.tar.gz"
  if [[ -z "${_CI_ASM_PKG_LOCATION}" ]]; then
    if [[ -n "${HTTPS_PROXY}" ]]; then
      HTTPS_PROXY="${HTTPS_PROXY}" curl -L "https://storage.googleapis.com/gke-release/asm/${TARBALL}" \
        | tar xz
    else
      curl -L "https://storage.googleapis.com/gke-release/asm/${TARBALL}" \
        | tar xz
    fi
  else
    local TOKEN; TOKEN="$(retry 2 gcloud --project="${PROJECT_ID}" auth print-access-token)"
    run_command curl -L "https://storage.googleapis.com/${_CI_ASM_PKG_LOCATION}/asm/${TARBALL}" \
      --header @- <<EOF | tar xz
Authorization: Bearer ${TOKEN}
EOF
  fi

  ln -s "${ISTIOCTL_REL_PATH}" .
  version_message > "${ASM_VERSION_FILE}"
}

download_kpt_package() {
  local SAMPLES_URL HTTPS_PROXY
  SAMPLES_URL="${KPT_URL/asm@/samples@}"
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"

  info "Downloading ASM kpt package..."
  if [[ -n "${HTTPS_PROXY}" ]]; then
    HTTPS_PROXY="${HTTPS_PROXY}" retry 3 kpt pkg get --auto-set=false "${KPT_URL}" asm
    HTTPS_PROXY="${HTTPS_PROXY}" retry 3 kpt pkg get --auto-set=false "${SAMPLES_URL}" samples
  else
    retry 3 kpt pkg get --auto-set=false "${KPT_URL}" asm
    retry 3 kpt pkg get --auto-set=false "${SAMPLES_URL}" samples
  fi

  touch "${ASM_SETTINGS_FILE}"
}

set_kpt_configured() {
  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local CA; CA="$(context_get-option "CA")"

  echo "${MANAGED} ${CA}" >| "${ASM_SETTINGS_FILE}"
}

should_download_kpt_package() {
  if [[ ! -f "${ASM_SETTINGS_FILE}" ]]; then return; fi
  if [[ ! -s "${ASM_SETTINGS_FILE}" ]]; then
    # Empty ASM settings file means kpt packages already exist but haven't been configured yet.
    # No need to re-download in this case
    false
    return
  fi

  local MANAGED; MANAGED="$(context_get-option "MANAGED")"
  local CA; CA="$(context_get-option "CA")"

  local PREV_MANAGED PREV_CA
  read -r PREV_MANAGED PREV_CA <"${ASM_SETTINGS_FILE}"

  if [[ "${MANAGED}" -ne "${PREV_MANAGED}" || "${PREV_CA}" != "${CA}" ]]; then
    warn "Configuration has changed since last run, scheduling re-download of kpt package"
    return
  fi

  false
}

# LTS releases don't have curl 7.55 so we can't use the @- construction,
# using -K keeps the token from printing if this script is run with -v
auth_header() {
  local TOKEN; TOKEN="${1}"
  echo "--header \"Authorization: Bearer ${TOKEN}\""
}

prepare_environment() {
  set_up_local_workspace
  validate_cli_dependencies

  if is_sa; then
    auth_service_account
  fi

  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  configure_kubectl "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}"

  if should_validate || can_modify_at_all; then
    local_iam_user > /dev/null
    if is_gcp && ! using_connect_gateway; then
      validate_gcp_resources
    fi
  fi

  if needs_asm; then
    # Offline mode should not trigger any download
    if is_offline; then
      if needs_kpt || ! necessary_files_exist || should_download_kpt_package; then
        { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Critical components not found in the offline mode. Note that if the installation configuration has changed,
kpt packages would have to be re-downloaded. Please run "asmcli build-offline-package"
and pass the directory containing the required files to install ASM successfully offline.
EOF
      fi
    fi

    if needs_kpt; then
      download_kpt
    fi
    readonly AKPT

    if ! necessary_files_exist; then
      download_asm
    fi
    if should_download_kpt_package; then
      download_kpt_package
    fi
    organize_kpt_files
  fi
}

init() {
  # BSD-style readlink apparently doesn't have the same -f toggle on readlink
  case "$(uname)" in
    Linux ) APATH="readlink";;
    Darwin) APATH="stat";;
    *);;
  esac
  readonly APATH

  local REVISION_LABEL
  KPT_BRANCH="${_CI_ASM_KPT_BRANCH:-main}"
  if [[ "${POINT}" == "alpha" ]]; then
    RELEASE="${MAJOR}.${MINOR}-alpha.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}"
  elif [[ "$(version_message)" =~ ^[0-9]+\.[0-9]+\.[0-9]+-asm\.[0-9]+\+config[0-9]+$ ]]; then
    RELEASE="${MAJOR}.${MINOR}.${POINT}-asm.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}-${REV}"
    KPT_BRANCH="${_CI_ASM_KPT_BRANCH:-$(version_message)}"
  else
    RELEASE="${MAJOR}.${MINOR}.${POINT}-asm.${REV}"
    REVISION_LABEL="${_CI_REVISION_PREFIX}asm-${MAJOR}${MINOR}${POINT}-${REV}"
  fi
  RELEASE_LINE="${MAJOR}.${MINOR}."
  PREVIOUS_RELEASE_LINE="${MAJOR}.$(( MINOR - 1 ))."
  context_set-option "REVISION_LABEL" "${REVISION_LABEL}"
  readonly RELEASE; readonly RELEASE_LINE; readonly PREVIOUS_RELEASE_LINE; readonly KPT_BRANCH;

  KPT_URL="https://github.com/GoogleCloudPlatform/anthos-service-mesh-packages"
  KPT_URL="${KPT_URL}.git/asm@${KPT_BRANCH}"; readonly KPT_URL;
  ISTIO_FOLDER_NAME="istio-${RELEASE}"; readonly ISTIO_FOLDER_NAME;
  ISTIOCTL_REL_PATH="${ISTIO_FOLDER_NAME}/bin/istioctl"; readonly ISTIOCTL_REL_PATH;
  PACKAGE_DIRECTORY="asm/istio"; readonly PACKAGE_DIRECTORY;
  VALIDATION_FIX_FILE_NAME="istiod-service.yaml"; readonly VALIDATION_FIX_FILE_NAME;
  VALIDATION_FIX_SERVICE="${PACKAGE_DIRECTORY}/${VALIDATION_FIX_FILE_NAME}"; readonly VALIDATION_FIX_SERVICE;
  OPTIONS_DIRECTORY="${PACKAGE_DIRECTORY}/options"; readonly OPTIONS_DIRECTORY;
  OPERATOR_MANIFEST="${PACKAGE_DIRECTORY}/istio-operator.yaml"; readonly OPERATOR_MANIFEST;
  BETA_CRD_MANIFEST="${OPTIONS_DIRECTORY}/v1beta1-crds.yaml"; readonly BETA_CRD_MANIFEST;
  CITADEL_MANIFEST="${OPTIONS_DIRECTORY}/citadel-ca.yaml"; readonly CITADEL_MANIFEST;
  MANAGED_CNI="${OPTIONS_DIRECTORY}/cni-managed.yaml"; readonly MANAGED_CNI;
  MANAGED_MANIFEST="${OPTIONS_DIRECTORY}/managed-control-plane.yaml"; readonly MANAGED_MANIFEST;
  EXPOSE_ISTIOD_DEFAULT_SERVICE="${PACKAGE_DIRECTORY}/expansion/expose-istiod.yaml"; readonly EXPOSE_ISTIOD_DEFAULT_SERVICE;
  EXPOSE_ISTIOD_REVISION_SERVICE="${PACKAGE_DIRECTORY}/expansion/expose-istiod-rev.yaml"; readonly EXPOSE_ISTIOD_REVISION_SERVICE;
  EXPANSION_GATEWAY_FILE="${PACKAGE_DIRECTORY}/expansion/vm-eastwest-gateway.yaml"; readonly EXPANSION_GATEWAY_FILE;
  CANONICAL_CONTROLLER_MANIFEST="asm/canonical-service/controller.yaml"; readonly CANONICAL_CONTROLLER_MANIFEST;
  ASM_VERSION_FILE=".asm_version"; readonly ASM_VERSION_FILE;
  ASM_SETTINGS_FILE=".asm_settings"; readonly ASM_SETTINGS_FILE;

  CR_CONTROL_PLANE_REVISION_REGULAR="asm/control-plane-revision/cr_regular.yaml"; readonly CR_CONTROL_PLANE_REVISION_REGULAR;
  CR_CONTROL_PLANE_REVISION_RAPID="asm/control-plane-revision/cr_rapid.yaml"; readonly CR_CONTROL_PLANE_REVISION_RAPID;
  CR_CONTROL_PLANE_REVISION_STABLE="asm/control-plane-revision/cr_stable.yaml"; readonly CR_CONTROL_PLANE_REVISION_STABLE;
  REVISION_LABEL_REGULAR="asm-managed"; readonly REVISION_LABEL_REGULAR
  REVISION_LABEL_RAPID="asm-managed-rapid"; readonly REVISION_LABEL_RAPID
  REVISION_LABEL_STABLE="asm-managed-stable"; readonly REVISION_LABEL_STABLE

  AKUBECTL="$(which kubectl || true)"; readonly AKUBECTL;
  AGCLOUD="$(which gcloud || true)"; readonly AGCLOUD;
  AKPT="$(which kpt || true)"
}

### Convenience functions ###

apath() {
  "${APATH}" "${@}"
}

gcloud() {
  local HTTPS_PROXY
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"

  if [[ -n "${HTTPS_PROXY}" ]]; then
    HTTPS_PROXY="${HTTPS_PROXY}" run_command "${AGCLOUD}" "${@}"
  else
    run_command "${AGCLOUD}" "${@}"
  fi
}

kubectl() {
  local KCF KCC HTTPS_PROXY
  KCF="$(context_get-option "KUBECONFIG")"
  KCC="$(context_get-option "CONTEXT")"
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"

  # Catch old codepaths that don't use context_set
  if [[ -z "${KCF}" ]]; then
    KCF="${KUBECONFIG}"
  fi

  # If we still
  if [[ -z "${KCF}" ]]; then
    KCF="$(mktemp)"
  fi

  local CMD
  CMD="${AKUBECTL}"
  if [[ -n "${KCF}" ]]; then
    CMD="${CMD} --kubeconfig ${KCF}"
  fi
  if [[ -n "${KCC}" ]]; then
    CMD="${CMD} --context ${KCC}"
  fi

  if [[ -n "${HTTPS_PROXY}" ]]; then
    # shellcheck disable=SC2086
    HTTPS_PROXY="${HTTPS_PROXY}" ${CMD} "${@}"
  else
    # shellcheck disable=SC2086
    run_command ${CMD} "${@}"
  fi
}

kpt() {
  run_command "${AKPT}" "${@}"
}

istioctl() {
  local KCF KCC HTTPS_PROXY
  KCF="$(context_get-option "KUBECONFIG")"
  KCC="$(context_get-option "CONTEXT")"
  HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"
  if [[ -z "${KCF}" ]]; then
    KCF="${KUBECONFIG}"
  fi

  if [[ -n "${HTTPS_PROXY}" ]]; then
    HTTPS_PROXY="${HTTPS_PROXY}" run_command "$(istioctl_path)" --kubeconfig "${KCF}" --context "${KCC}" "${@}"
  else
    run_command "$(istioctl_path)" --kubeconfig "${KCF}" --context "${KCC}" "${@}"
  fi
}

istioctl_path() {
  if [[ -n "${_CI_ISTIOCTL_REL_PATH}" && -f "${_CI_ISTIOCTL_REL_PATH}" ]]; then
    echo "${_CI_ISTIOCTL_REL_PATH}"
  else
    echo "./${ISTIOCTL_REL_PATH}"
  fi
}

verify_connectivity() {
  info "Verifying connectivity (10s)..."
  local ADDR
  ADDR="$(kubectl config view --minify=true -ojson | \
    jq .clusters[0].cluster.server -r)"
  ADDR="${ADDR:8:${#ADDR}}"
  ADDR="${ADDR%:*}"

  local RETVAL; RETVAL=0;
  run_command nc -zvw 10 "${ADDR}" 443 || RETVAL=$?
  if [[ "${RETVAL}" -ne 0 ]]; then
    { read -r -d '' MSG; fatal "${MSG}"; } <<EOF || true
Couldn't connect to ${CLUSTER_NAME}.
If this is a private cluster, verify that the correct firewall rules are applied.
https://cloud.google.com/service-mesh/docs/gke-install-overview#requirements
EOF
  fi
}

add_trust_domain_alias() {
  local TRUST_DOMAIN_ALIASES
  TRUST_DOMAIN_ALIASES="$(context_get-option "TRUST_DOMAIN_ALIASES")"
  if [[ "${TRUST_DOMAIN_ALIASES}" == *${1}* ]]; then
    return
  fi
  TRUST_DOMAIN_ALIASES="${TRUST_DOMAIN_ALIASES} ${1}"
  context_set-option "TRUST_DOMAIN_ALIASES" "${TRUST_DOMAIN_ALIASES}"
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
  local KUBECONFIG_SUPPLIED; KUBECONFIG_SUPPLIED="$(context_get-option "KUBECONFIG_SUPPLIED")"
  local KUBECONFIG; KUBECONFIG="$(context_get-option "KUBECONFIG")"

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
      if is_offline; then
        fatal "${OUTPUT_DIR} must exist for offline installation."
      fi
      if ! mkdir -p "${OUTPUT_DIR}"; then
        fatal "Failed to create directory ${OUTPUT_DIR}"
      fi
    elif [[ ! -d "${OUTPUT_DIR}" ]]; then
      fatal "${OUTPUT_DIR} exists and is not a directory, please specify another directory."
    fi
  fi

  if [[ -x "${OUTPUT_DIR}/kpt" ]]; then AKPT="$(apath -f "${OUTPUT_DIR}/kpt")"; fi

  pushd "$OUTPUT_DIR" > /dev/null
  context_set-option "OUTPUT_DIR" "${OUTPUT_DIR}"

  if [[ "${KUBECONFIG_SUPPLIED}" -eq 0 ]]; then
    KUBECONFIG="$(pwd)/asm_kubeconfig"
    context_set-option "KUBECONFIG" "${KUBECONFIG}"
  fi

  if [[ -n "${KUBECONFIG}" && ! -f "${KUBECONFIG}" ]]; then
    touch "${KUBECONFIG}"
  fi

  info "Using ${KUBECONFIG} as the kubeconfig..."
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

post_process_istio_yamls() {
  handle_multi_yaml_bug

  while read -d ',' -r yaml_file; do
    context_append "istioctlFiles" "${yaml_file}"
  done <<EOF
$(context_get-option "CUSTOM_OVERLAY")
EOF
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

populate_cluster_values() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local NETWORK_ID; NETWORK_ID="$(context_get-option "NETWORK_ID")"
  local CLUSTER_DATA

  if is_gcp; then
    CLUSTER_DATA="$(retry 2 gcloud container clusters describe "${CLUSTER_NAME}" \
      --zone="${CLUSTER_LOCATION}" \
      --project="${PROJECT_ID}" \
      --format='value(selfLink, network)')"
    read -r NEW_GKE_CLUSTER_URI NEW_NETWORK_ID <<EOF
${CLUSTER_DATA}
EOF

    if not_null "${NEW_GKE_CLUSTER_URI}"; then
      context_set-option "GKE_CLUSTER_URI" "${NEW_GKE_CLUSTER_URI}"
    fi
    if not_null "${NEW_NETWORK_ID}"; then
      context_set-option "NETWORK_ID" "${PROJECT_ID}-${NEW_NETWORK_ID}"
    fi
  else
    if [[ -z "${NETWORK_ID}" ]]; then
      context_set-option "NETWORK_ID" "default"
    fi
  fi
}

# Reads in stdin, expected in the form of kubectl config get-contexts
# output and isolates the default context's cluster value.
get_context_cluster() {
  grep '^\*' | cut -c2- | sed 's/\([[:blank:]]\)*\1/\1/g' | cut -d ' ' -f 3
}

init_meshconfig_curl() {
  local POST_DATA; POST_DATA="${1}"
  local ID; ID="${2}"
  local HTTPS_PROXY; HTTPS_PROXY="$(context_get-option "HTTPS_PROXY")"
  local DRY_RUN; DRY_RUN="$(context_get-option "DRY_RUN")"

  # The proxy data gets eaten by run_command but we don't want to print
  # it anyways, so we only use the top version if we have proxy info
  # AND it's not a dry run.
  if [[ -n "${HTTPS_PROXY}" && "${DRY_RUN}" -eq 0 ]]; then
    HTTPS_PROXY="${HTTPS_PROXY}" curl --request POST --fail \
      --data "${POST_DATA}" -o /dev/null \
      "https://meshconfig.googleapis.com/v1alpha1/projects/${ID}:initialize" \
      --header "X-Server-Timeout: 600" \
      --header "Content-Type: application/json" \
      -K <(auth_header "$(get_auth_token)")
  else
    run_command curl --request POST --fail \
      --data "${POST_DATA}" -o /dev/null \
      "https://meshconfig.googleapis.com/v1alpha1/projects/${ID}:initialize" \
      --header "X-Server-Timeout: 600" \
      --header "Content-Type: application/json" \
      -K <(auth_header "$(get_auth_token)")
  fi
}

get_gke_release_channel() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  gcloud container clusters describe \
    --project="${PROJECT_ID}" \
    --region "${CLUSTER_LOCATION}" \
    "${CLUSTER_NAME}" \
    --format="value(releaseChannel.channel)"
}

get_cr_channel() {
  local CHANNEL; CHANNEL="$(context_get-option "CHANNEL")"
  if [[ -n "${CHANNEL}" ]]; then
    echo "${CHANNEL}"
  elif ! is_gcp; then
    echo regular
  else
    local GKE_CHANNEL; GKE_CHANNEL="$(get_gke_release_channel)"
    case "${GKE_CHANNEL}" in
      regular)
        echo regular
        ;;
      rapid)
        echo rapid
        ;;
      stable)
        echo stable
        ;;
      *)
        echo regular
        ;;
    esac
  fi
}

get_cr_yaml() {
  local CHANNEL; CHANNEL="${1}"
  local CR REVISION
  case "${CHANNEL}" in
    regular)
      CR="${CR_CONTROL_PLANE_REVISION_REGULAR}"
      REVISION="${REVISION_LABEL_REGULAR}"
      ;;
    stable)
      CR="${CR_CONTROL_PLANE_REVISION_STABLE}"
      REVISION="${REVISION_LABEL_STABLE}"
      ;;
    *)
      CR="${CR_CONTROL_PLANE_REVISION_RAPID}"
      REVISION="${REVISION_LABEL_RAPID}"
      ;;
  esac
  echo "${CR} ${REVISION}"
}

ensure_cross_project_service_accounts() {
  local FLEET_ID; FLEET_ID="${1}"
  local PROJECT_ID; PROJECT_ID="${2}"

  if ! is_gcp; then return; fi

  local FLEET_HOST_PROJECT_NUMBER
  FLEET_HOST_PROJECT_NUMBER="$(gcloud projects describe "${FLEET_ID}" --format "value(projectNumber)")"

  local FLEET_SA
  local MESH_SA
  FLEET_SA="serviceAccount:service-${FLEET_HOST_PROJECT_NUMBER}@gcp-sa-gkehub.iam.gserviceaccount.com"
  MESH_SA="serviceAccount:service-${FLEET_HOST_PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com"

  if ! ensure_cross_project_sa "${FLEET_ID}" "${PROJECT_ID}" "${FLEET_SA}" "roles/gkehub.serviceAgent"; then
    warn "The Fleet service account may not have been created for the Fleet hosted in ${FLEET_ID}."
    warn "Please refer to https://cloud.google.com/anthos/multicluster-management/connect/prerequisites#gke-cross-project"
    warn "for information on how to create the identity and grant permissions. You may also re-run this command"
    warn "with either the --enable-all or --enable-gcp-iam-roles flag to automatically create the IAM bindings."
  fi

  if ! ensure_cross_project_sa "${FLEET_ID}" "${PROJECT_ID}" "${MESH_SA}" "roles/anthosservicemesh.serviceAgent"; then
    warn "The Mesh service account may not have been created for the Fleet hosted in ${FLEET_ID}."
    warn "Please add an IAM binding for service-${FLEET_HOST_PROJECT_NUMBER}@gcp-sa-servicemesh.iam.gserviceaccount.com"
    warn "with a role binding for roles/anthosservicemesh.serviceAgent. You may also re-run this command"
    warn "with either the --enable-all or --enable-gcp-iam-roles flag to automatically create the IAM bindings."
  fi
}

ensure_cross_project_sa() {
  local FLEET_ID; FLEET_ID="${1}"
  local PROJECT_ID; PROJECT_ID="${2}"
  local SA_NAME; SA_NAME="${3}"
  local ROLE; ROLE="${4}"
  local ENABLE_ALL; ENABLE_ALL="$(context_get-option "ENABLE_ALL")"
  local ENABLE_GCP_IAM_ROLES; ENABLE_GCP_IAM_ROLES="$(context_get-option "ENABLE_GCP_IAM_ROLES")"

  local FLEET_POLICIES
  FLEET_POLICIES="$(gcloud projects get-iam-policy "${FLEET_ID}" --format=json)"

  if [[ -z "${FLEET_POLICIES}" ]]; then
    false
    return
  fi

  if ! echo "${FLEET_POLICIES}" | grep -q "${SA_NAME}"; then
    false
    return
  fi

  local PROJECT_POLICY_MEMBERS
  PROJECT_POLICY_MEMBERS="$(gcloud projects get-iam-policy "${PROJECT_ID}" --format=json)"

  if [[ -z "${PROJECT_POLICY_MEMBERS}" ]]; then
    false
    return
  fi

  PROJECT_POLICY_MEMBERS="$(echo "${PROJECT_POLICY_MEMBERS}" | jq '.bindings[] | select(.role == "'"${ROLE}"'")')"

  if [[ -n "${PROJECT_POLICY_MEMBERS}" ]]; then
    PROJECT_POLICY_MEMBERS="$(echo "${PROJECT_POLICY_MEMBERS}" | jq '.members[]')"
  fi

  if [[ "${PROJECT_POLICY_MEMBERS}" == *"${SA_NAME}"* ]]; then
    return
  fi


  if [[ "${ENABLE_ALL}" -eq 1 || "${ENABLE_GCP_IAM_ROLES}" -eq 1 ]]; then
    bind_user_to_iam_policy "${ROLE}" "${SA_NAME}"
    true
    return
  fi
  false
}

