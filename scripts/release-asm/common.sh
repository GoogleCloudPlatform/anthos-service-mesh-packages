_DEBUG="${_DEBUG:=}"
if [[ "${_DEBUG}" -eq 1 ]]; then
  gsutil() {
    echo "DEBUG: would have run 'gsutil ${*}'"
  }

  git() {
    echo "DEBUG: would have run 'git ${*}'"
  }
fi

BUCKET_URL="https://storage.googleapis.com"
BUCKET_PATH="csm-artifacts/asm"; readonly BUCKET_PATH

CURRENT_RELEASE="release-1.10-asm"; readonly CURRENT_RELEASE

STABLE_VERSION_FILE="STABLE_VERSIONS"; readonly STABLE_VERSION_FILE
STABLE_VERSION_FILE_PATH="${BUCKET_PATH}/${STABLE_VERSION_FILE}"; readonly STABLE_VERSION_FILE_PATH
HOLD_TYPE="temp"; readonly HOLD_TYPE
trap 'gsutil retention "${HOLD_TYPE}" release gs://"${STABLE_VERSION_FILE_PATH}"' ERR # hope that the hold is cleared

prod_releases() {
  cat << EOF
release 1.10
release 1.9
release 1.8
release 1.7
EOF
}

staging_releases() {
  cat << EOF
staging 1.10
staging 1.9
staging 1.8
EOF
}

other_releases() {
  cat << EOF
master unstable
EOF
}

# all_releases should write two strings to stdout: <branch-name> <file-suffix>
# <file_suffix> is the string that comes after the script name in the GCS bucket
# e.g. the pair "branch" "demo" will check out the git branch "branch" and
# upload a file called "<SCRIPT_NAME>_demo" to the GCS bucket.
all_releases() {
  while read -r type version; do
    echo "${type}-${version}-asm" "${version}"
  done <<EOF
$(prod_releases)
EOF
  while read -r type version; do
    echo "${type}-${version}-asm" "staging_${version}"
  done <<EOF
$(staging_releases)
EOF
  while read -r type version; do
    echo "${type}" "${version}"
  done <<EOF
$(other_releases)
EOF
}

is_proper_tag() {
  local TAG; TAG="${1}"
  if [[ ! "${TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-asm\.[0-9]+\+config[0-9]+$ ]]; then false; fi
}

is_on_hold() {
  local HOLD_STATUS; HOLD_STATUS="$(gsutil stat gs://${STABLE_VERSION_FILE_PATH} | grep -i ${HOLD_TYPE})"
  if [[ ! "${HOLD_STATUS}" =~ "Enabled" ]]; then false; fi
}

all_release_tags() {
  while read -r TAG; do
    if is_proper_tag "${TAG}"; then
      echo "${TAG}"
    fi
  done <<EOF
$(git tag)
EOF
}

changes_necessary() {
  local URI; URI="${1}";
  local NAME; NAME="${2}";

  if curl -O "${URI}.sha256"; then
    if sha256sum -c --ignore-missing "${NAME}.sha256" >/dev/null 2>/dev/null; then
      echo "No changes in ${NAME}, skipping"
      rm "${NAME}.sha256"
      false
      return
    fi
    rm "${NAME}.sha256"
  else
    echo "New file {FILE_NAME}"
  fi
}

check_tags() {
  local BRANCH_NAME; BRANCH_NAME="${1}";
  local SCRIPT_NAME; SCRIPT_NAME="${2}";

  local TAG; TAG="$(git tag --points-at HEAD)";
  local VER; VER="$(./"${SCRIPT_NAME}" --version 2>/dev/null || true)";

  if [[ "${_DEBUG}" -eq 1 ]]; then
    echo "DEBUG: Tag: ${TAG} Version: ${VER}"
    return
  fi

  if [[ "${BRANCH_NAME}" = release* && "${TAG}" == "" ]]; then
    echo "Release branches must be tagged before releasing. Aborting."
    exit 1
  fi

  if [[ "${TAG}" != "" && "${VER}" != "${TAG}" ]]; then
    echo "${SCRIPT_NAME} version and git tag don't match. Aborting."
    exit 1
  fi
}

get_stable_version() {
  local VER; VER="$(./"${SCRIPT_NAME}" --version 2>/dev/null || true)"

  if [[ "${VER}" == "" ]]; then
    VER="$(git tag --points-at HEAD)"
  fi

  echo "${VER}"
}

get_version_file_and_lock() {
  if ! gsutil -q stat "gs://${STABLE_VERSION_FILE_PATH}"; then
    echo "[ERROR]: file does not exist: ${STABLE_VERSION_FILE_PATH}." >&2
    exit 1
  fi

  if is_on_hold; then
    echo "[ERROR]: file already on hold: ${STABLE_VERSION_FILE_PATH}." >&2
    exit 1
  fi
  gsutil retention "${HOLD_TYPE}" set "gs://${STABLE_VERSION_FILE_PATH}"
  gsutil cp "gs://${STABLE_VERSION_FILE_PATH}" .
}

upload_version_file_and_unlock() {
  TMPFILE="$(mktemp)"
  sort -r "${STABLE_VERSION_FILE}" | uniq >> "${TMPFILE}" && mv "${TMPFILE}" "${STABLE_VERSION_FILE}"

  gsutil retention "${HOLD_TYPE}" release gs://"${STABLE_VERSION_FILE_PATH}"
  gsutil cp "${STABLE_VERSION_FILE}" gs://"${STABLE_VERSION_FILE_PATH}"
  gsutil acl ch -u AllUsers:R gs://"${STABLE_VERSION_FILE_PATH}"
}

upload() {
  local SCRIPT_NAME; SCRIPT_NAME="${1}";
  local FILE_NAME; FILE_NAME="${2}";
  local FILE_PATH; FILE_PATH="${3}";
  local FILE_URI; FILE_URI="${4}";

  gsutil cp "${FILE_NAME}" gs://"${FILE_PATH}"
  gsutil cp "${SCRIPT_NAME}.sha256" gs://"${FILE_PATH}.sha256"
  gsutil acl ch -u AllUsers:R gs://"${FILE_PATH}" gs://"${FILE_PATH}.sha256"

  curl -O "${FILE_URI}"
  curl -O "${FILE_URI}.sha256"

  sha256sum -c --ignore-missing "${FILE_NAME}.sha256" || echo "Failed to verify ${FILE_NAME}!" >&2
}

publish_script() {
  local BRANCH_NAME; BRANCH_NAME="${1}"
  local VERSION; VERSION="${2}"
  local SCRIPT_NAME; SCRIPT_NAME="${3}"
  local STABLE_VERSION;

  git checkout "${BRANCH_NAME}"

  if [[ ! -f "${SCRIPT_NAME}" ]]; then echo "${SCRIPT_NAME} not found" >&2; return; fi

  check_tags "${BRANCH_NAME}" "${SCRIPT_NAME}"

  STABLE_VERSION="$(get_stable_version)"
  write_and_upload "${SCRIPT_NAME}" "${VERSION}"
  write_and_upload "${SCRIPT_NAME}" "${STABLE_VERSION}"
}

write_and_upload() {
  local SCRIPT_NAME; SCRIPT_NAME="${1}"
  local VERSION; VERSION="${2}"
  local FILE_NAME; FILE_NAME="${SCRIPT_NAME}_${VERSION//+/-}"
  local FILE_PATH; FILE_PATH="${BUCKET_PATH}/${FILE_NAME}"
  local FILE_URI; FILE_URI="${BUCKET_URL}/${FILE_PATH}"

  if ! changes_necessary "${FILE_URI}" "${FILE_NAME}"; then return; fi

  sha256sum "${SCRIPT_NAME}" >| "${SCRIPT_NAME}.sha256"
  cp "${SCRIPT_NAME}" "${FILE_NAME}"
  sha256sum "${FILE_NAME}" >> "${SCRIPT_NAME}.sha256"

  upload "${SCRIPT_NAME}" "${FILE_NAME}" "${FILE_PATH}" "${FILE_URI}"

  if [[ "${BRANCH_NAME}" == "${CURRENT_RELEASE}" ]]; then
    upload "${SCRIPT_NAME}" "${FILE_NAME}" "${BUCKET_PATH}/${SCRIPT_NAME}" "${BUCKET_URL}/${BUCKET_PATH}/${SCRIPT_NAME}"
  fi

  if [[ "${BRANCH_NAME}" =~ "release" ]] || is_proper_tag "${VERSION}"; then
    append_version "${VERSION}" "${FILE_NAME}"
  fi

  git restore "${SCRIPT_NAME}"

  echo "Published ${FILE_NAME} successfully."
}

append_version() {
  local VERSION; VERSION="${1}"
  local FILE_NAME; FILE_NAME="${2}"
  echo "${VERSION}:${FILE_NAME}" >> "${STABLE_VERSION_FILE}"
}

setup() {
  tmpdir="$(mktemp -d)"
  pushd "${tmpdir}"
  git clone git@github.com:GoogleCloudPlatform/anthos-service-mesh-packages.git
  if [[ "${_DEBUG}" -ne 1 ]]; then
    cd anthos-service-mesh-packages/scripts/asm-installer
  else
    touch install_asm
  fi
}
