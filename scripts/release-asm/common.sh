_DEBUG="${_DEBUG:=}"
SCRIPT_PATH="${SCRIPT_PATH:=asmcli}"
RELEASE_MODE="${RELEASE_MODE:=default}"
PRECOMMIT="scripts/release-asm/precommit"
if [[ "${_DEBUG}" -eq 1 ]]; then
  gsutil() {
    echo "DEBUG: would have run 'gsutil ${*}'" >&2
  }

  git() {
    echo "DEBUG: would have run 'git ${*}'" >&2
  }

  curl() {
    echo "DEBUG: would have run 'curl ${*}'" >&2
  }
fi

BUCKET_URL="https://storage.googleapis.com"
BUCKET_PATH="csm-artifacts/asm"; readonly BUCKET_PATH

CURRENT_RELEASE="release-1.10-asmcli"; readonly CURRENT_RELEASE

STABLE_VERSION_FILE="ASMCLI_VERSIONS"; readonly STABLE_VERSION_FILE
STABLE_VERSION_FILE_PATH="${BUCKET_PATH}/${STABLE_VERSION_FILE}"; readonly STABLE_VERSION_FILE_PATH
HOLD_TYPE="temp"; readonly HOLD_TYPE
trap 'gsutil retention "${HOLD_TYPE}" release gs://"${STABLE_VERSION_FILE_PATH}"' ERR # hope that the hold is cleared

prod_releases() {
  :
}

staging_releases() {
  :
}

other_releases() {
  cat << EOF
main unstable
EOF
}

# all_releases should write two strings to stdout: <branch-name> <file-suffix>
# <file_suffix> is the string that comes after the script name in the GCS bucket
# e.g. the pair "branch" "demo" will check out the git branch "branch" and
# upload a file called "<SCRIPT_NAME>_demo" to the GCS bucket.
all_releases() {
#  while read -r type version; do
#    echo "${type}-${version}-asm" "${version}"
#  done <<EOF
#$(prod_releases)
#EOF
#  while read -r type version; do
#    echo "${type}-${version}-asm" "staging_${version}"
#  done <<EOF
#$(staging_releases)
#EOF
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
      echo "No changes in ${NAME}, skipping" >&2
      rm "${NAME}.sha256"
      false
      return
    fi
    rm "${NAME}.sha256"
  else
    echo "New file {FILE_NAME}" >&2
  fi
}

check_tags() {
  local BRANCH_NAME; BRANCH_NAME="${1}";
  local SCRIPT_NAME; SCRIPT_NAME="${2}";

  local TAG; TAG="$(git tag --points-at HEAD)";
  local VER; VER="$(./"${SCRIPT_NAME}" --version 2>/dev/null || true)";

  if [[ "${_DEBUG}" -eq 1 ]]; then
    echo "DEBUG: Tag: ${TAG} Version: ${VER}" >&2
    return
  fi

  if [[ "${BRANCH_NAME}" = release* && "${TAG}" == "" ]]; then
    echo "Release branches must be tagged before releasing. Aborting." >&2
    exit 1
  fi

  if [[ "${TAG}" != "" && "${VER}" != "${TAG}" ]]; then
    echo "${SCRIPT_NAME} version and git tag don't match. Aborting." >&2
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

  if [[ "${BRANCH_NAME}" =~ "release" && "${RELEASE_MODE}" = "auto" ]]; then
    auto_release "${VERSION}"
  fi

  git checkout "${BRANCH_NAME}"

  if [[ ! -f "${SCRIPT_NAME}" ]]; then echo "${SCRIPT_NAME} not found" >&2; return; fi

  check_tags "${BRANCH_NAME}" "${SCRIPT_NAME}"

  STABLE_VERSION="$(get_stable_version)"
  write_and_upload "${SCRIPT_NAME}" "${VERSION}"
  if [[ -n "${STABLE_VERSION}" ]]; then
    write_and_upload "${SCRIPT_NAME}" "${STABLE_VERSION}"
  else
    echo "No stable version found--skipping" >&2
  fi
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

  echo "Published ${FILE_NAME} successfully." >&2
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
    cd anthos-service-mesh-packages
    # remove this after the default branch is switched
    git checkout main
    cd asmcli
  else
    touch asmcli
  fi
}

prompt_for_confirmation() {
  local CONFIRMATION
  read -r -p "${1} [y/N] " CONFIRMATION
  case "${CONFIRMATION}" in
      [yY][eE][sS]|[yY])
          return
          ;;
  esac
  false
}

prompt_for_message() {
  local MSG
  read -r -p "Please provide a release message for ${1}:" MSG
  if [[ -n "${MSG}" ]]; then
    echo "${MSG}"
  fi
}

update_config_number() {
  local OLD_NUMBER; OLD_NUMBER="${1}"
  local NEW_NUMBER; NEW_NUMBER="${2}"

  sed -i.bak "s/CONFIG_VER:=\"${OLD_NUMBER}\"/CONFIG_VER:=\"${NEW_NUMBER}\"/g" "${SCRIPT_PATH}.sh"

  bazel build //:merge && cp ../bazel-bin/asmcli .
}

auto_release() {
  local VERSION; VERSION="${1}"
  local RELEASE_BRANCH; RELEASE_BRANCH="release-${VERSION}-asm"
  local STAGING_BRANCH; STAGING_BRANCH="staging-${VERSION}-asm"
  local DELTA_COMMITS
  local RELEASE_STABLE_VERSION NEW_RELEASE_STABLE_VERSION STAGING_STABLE_VERSION
  local OLD_NUMBER NEW_NUMBER
  local TAG_MESSAGE

  git checkout "${STAGING_BRANCH}"
  STAGING_STABLE_VERSION="$(./${SCRIPT_PATH} --version)"

  git checkout "${RELEASE_BRANCH}"
  RELEASE_STABLE_VERSION="$(./${SCRIPT_PATH} --version)"

  DELTA_COMMITS="$(git log "${RELEASE_BRANCH}..${STAGING_BRANCH}")"
  if [[ -z "${DELTA_COMMITS}" ]]; then
    echo "${RELEASE_BRANCH} branch is up-to-date with ${STAGING_BRANCH} branch. Nothing to merge."
  else
    OLD_NUMBER="${RELEASE_STABLE_VERSION##*config}"
    if [[ "${RELEASE_STABLE_VERSION%config*}" == "${STAGING_STABLE_VERSION%config*}" ]]; then
      NEW_NUMBER="$((OLD_NUMBER+1))"
    else
      NEW_NUMBER=1
    fi
    NEW_RELEASE_STABLE_VERSION="${STAGING_STABLE_VERSION%config*}config${NEW_NUMBER}"
    cat <<EOF
Merging staging into release...
Commits to be merged from ${STAGING_BRANCH} to ${RELEASE_BRANCH}:
${DELTA_COMMITS}

Old version: ${RELEASE_STABLE_VERSION}
New version: ${NEW_RELEASE_STABLE_VERSION}
EOF
    prompt_for_confirmation "Do you want to proceed?" || false
    git merge --strategy-option=theirs "${STAGING_BRANCH}" --no-edit || git add -u && (git diff-index --quiet HEAD || git commit --no-edit)  # in case of modify/delete

    # Update CONFIG_VER if necessary
    update_config_number "${OLD_NUMBER}" "${NEW_NUMBER}"
    if [[ "${NEW_RELEASE_STABLE_VERSION}" != "$(./${SCRIPT_PATH} --version)" ]]; then
      echo "Error when updating the config number. Expected: ${NEW_RELEASE_STABLE_VERSION} Got: $(./${SCRIPT_PATH} --version)"
      false
    fi

    # Commit the CONFIG_NUMBER change
    git add -u && git commit -m "update the version from ${RELEASE_STABLE_VERSION} to ${NEW_RELEASE_STABLE_VERSION}"
  fi

  prompt_for_confirmation "Do you want to create tag ${NEW_RELEASE_STABLE_VERSION}?" || false
  tag_sign_verify "${NEW_RELEASE_STABLE_VERSION}"

  # Push new changes to remote
  prompt_for_confirmation "Do you want to push your local changes to remote?" || false
  push_branch_to_remote "${RELEASE_BRANCH}"
  push_tag_to_remote "${NEW_RELEASE_STABLE_VERSION}"
}

tag_sign_verify() {
  local VERSION; VERSION="${1}"
  echo "Tagging, signing and verifying the release..."
  TAG_MESSAGE="$(prompt_for_message "${VERSION}")"
  git tag -s "${VERSION}" -m "${TAG_MESSAGE}" # tag and sign
  git tag -v "${VERSION}" # verify
}

push_tag_to_remote() {
  local TAG; TAG="${1}"
  if git ls-remote --tags | grep -q "${TAG}"; then
    echo "${TAG} already exists in remote!"
    return
  fi

  git push origin "${TAG}"
}

push_branch_to_remote() {
  local BRANCH; BRANCH="${1}"

  git push origin "${BRANCH}"
}
