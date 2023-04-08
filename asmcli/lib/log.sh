LOG_FILE_PATH="$(pwd)/$(uuidgen).txt"; readonly LOG_FILE_PATH;

info() {
  local VERBOSE; VERBOSE="$(context_get-option "VERBOSE")"
  if hash ts 2>/dev/null && [[ "${VERBOSE}" -eq 1 ]]; then
    echo_log "${SCRIPT_NAME}: ${1}" | TZ=utc ts '%Y-%m-%dT%.T' >&2
  else
    echo_log "${SCRIPT_NAME}: ${1}" >&2
  fi
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

fatal() {
  error "${1}"
  exit 2
}

fatal_with_usage() {
  error "${1}"
  usage_short >&2
  exit 2
}

echo_log() {
  echo $@
  echo $@ >> $LOG_FILE_PATH
}
