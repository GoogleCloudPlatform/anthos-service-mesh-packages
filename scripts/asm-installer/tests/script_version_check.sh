#!/bin/bash
set -eu

INSTALL_ASM_SCRIPT="install_asm"; readonly INSTALL_ASM_SCRIPT;
ASM_VM_SCRIPT="asm_vm"; readonly ASM_VM_SCRIPT;

while read -r KEYWORD; do
  INSTALL_ASM_LINE="$(grep "^${KEYWORD}=" "${INSTALL_ASM_SCRIPT}")"
  if [[ -z "${INSTALL_ASM_LINE}" ]]; then
    echo "Cannot find line starting with ${KEYWORD}= in install_asm"
    exit 1
  fi
  ASM_VM_LINE="$(grep "^${KEYWORD}=" "${ASM_VM_SCRIPT}")"
  if [[ -z "${ASM_VM_LINE}" ]]; then
    echo "Cannot find line starting with ${KEYWORD}= in asm_vm"
    exit 1
  fi
  if [[ "${INSTALL_ASM_LINE}" != "${ASM_VM_LINE}" ]]; then
    echo "${KEYWORD} version line does not match in install_asm and asm_vm. Please make the change."
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
KPT_TAG="$(grep -A 1 'name: anthos.servicemesh.tag' ../../asm/Kptfile | tail -n 1 | sed 's/.*value: \(.*\)$/\1/g')"

if [[ "${V_STRING}" != "${KPT_TAG}" ]]; then
  echo "The version tag in the Kptfile doesn't match installation tools, please make the change."
  exit 1
fi

echo "Success: versions in the scripts are verified."
