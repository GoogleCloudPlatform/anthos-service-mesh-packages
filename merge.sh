#!/usr/bin/env bash
set -eEuC
set -o pipefail

# The first path is the output path, default to in bazel-bin/
out="${1}"
shift
touch "${out}"

{ 
  printf "%s\n" "#!/usr/bin/env bash" "set -CeE" "set -o pipefail"; 
  cat "$@"; 
  printf "\nmain \"\${@}\"\n"; 
} >> "${out}"
