context_init() {
  local JSON; JSON="${1}"
  context_FILE_LOCATION="$(mktemp)"; readonly context_FILE_LOCATION
  export context_FILE_LOCATION

  echo "${JSON}" >> "${context_FILE_LOCATION}"
}

context_get-option() {
  local OPTION; OPTION="${1}"

  jq -r --arg OPTION "${OPTION}" '.flags[$OPTION]' "${context_FILE_LOCATION}"
}

context_set-option() {
  local OPTION; OPTION="${1}"
  local VALUE; VALUE="${2}"
  local TEMP_FILE; TEMP_FILE="$(mktemp)"

  jq --arg OPTION "${OPTION}" --arg VALUE "${VALUE}" \
  '.flags[$OPTION]=($VALUE | try tonumber catch $VALUE)' "${context_FILE_LOCATION}" >| "${TEMP_FILE}" \
  && mv "${TEMP_FILE}" "${context_FILE_LOCATION}"
}

context_append-istio-yaml() {
  return
}

context_append-kube-yaml() {
  return
}
