#!/usr/bin/env bash

_common_setup() {
    source "node_modules/bats-support/load.bash"
    source "node_modules/bats-assert/load.bash"

    while read -r SOURCE_FILE; do
        source "$SOURCE_FILE"
    done <<EOF
${SOURCE_FILES}
EOF
}
