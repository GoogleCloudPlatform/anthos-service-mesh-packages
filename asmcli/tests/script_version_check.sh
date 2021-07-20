#!/bin/bash
set -eu

INSTALL_ASM_SCRIPT="asmcli"; readonly INSTALL_ASM_SCRIPT;

while read -r KEYWORD; do
  INSTALL_ASM_LINE="$(grep "^${KEYWORD}=" "${INSTALL_ASM_SCRIPT}")"
  if [[ -z "${INSTALL_ASM_LINE}" ]]; then
    echo "Cannot find line starting with ${KEYWORD}= in asmcli"
    exit 1
  fi
  eval ${INSTALL_ASM_LINE}
done <<EOF
MAJOR
MINOR
POINT
REV
EOF

V_STRING="${MAJOR}.${MINOR}.${POINT}-asm.${REV}"
KPT_TAG="$(grep -A 1 'name: anthos.servicemesh.tag' ../asm/Kptfile | tail -n 1 | sed 's/.*value: \(.*\)$/\1/g')"

if [[ "${V_STRING}" != "${KPT_TAG}" ]]; then
  echo "The version tag in the Kptfile doesn't match installation tools, please make the change."
  exit 1
fi

echo "Success: versions in the scripts are verified."
