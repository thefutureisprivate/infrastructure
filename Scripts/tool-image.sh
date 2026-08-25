#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
lock_file="${repo_root}/Tools/compose.yaml"

if (($# != 1)) || [[ ! $1 =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'Usage: %s <tool-service>\n' "$0" >&2
  exit 2
fi
service=$1

mapfile -t references < <(
  awk -v wanted="${service}" '
    $0 == "  " wanted ":" { selected = 1; next }
    selected && /^  [a-z0-9][a-z0-9-]*:$/ { exit }
    selected && /^[[:space:]]+image:[[:space:]]+"[^"]+"[[:space:]]*$/ {
      value = $0
      sub(/^[[:space:]]+image:[[:space:]]+"/, "", value)
      sub(/"[[:space:]]*$/, "", value)
      print value
    }
  ' "${lock_file}"
)

if ((${#references[@]} != 1)); then
  printf 'Expected exactly one image for Tools service %s in %s\n' \
    "${service}" "${lock_file}" >&2
  exit 1
fi
if [[ ! ${references[0]} =~ :[^/@]+@sha256:[0-9a-f]{64}$ ]]; then
  printf 'Tool image %s is not pinned by exact tag and sha256 digest\n' \
    "${service}" >&2
  exit 1
fi

printf '%s\n' "${references[0]}"
