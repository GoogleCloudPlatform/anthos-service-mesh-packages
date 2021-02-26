#!/bin/bash
set -eu

while read -r KEYWORD; do
  INSTALL_ASM_LINE="$(grep "^${KEYWORD}=" ../install_asm)"
  if [[ -z "${INSTALL_ASM_LINE}" ]]; then
    echo "Cannot find line starting with ${KEYWORD}= in install_asm"
    exit 1
  fi
  ASM_VM_LINE="$(grep "^${KEYWORD}=" ../asm_vm)"
  if [[ -z "${ASM_VM_LINE}" ]]; then
    echo "Cannot find line starting with ${KEYWORD}= in asm_vm"
    exit 1
  fi
  if [[ "${INSTALL_ASM_LINE}" != "${ASM_VM_LINE}" ]]; then
    echo "${KEYWORD} version line does not match in install_asm and asm_vm. Please make the change."
    exit 1
  fi
done <<EOF
MAJOR
MINOR
POINT
REV
EOF