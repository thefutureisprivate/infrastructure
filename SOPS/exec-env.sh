#!/usr/bin/env bash
set -euo pipefail

sops_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
secrets_file=${SOPS_SECRETS_FILE:-"${sops_dir}/infrastructure.sops.yaml"}

if (( $# < 4 )) || [[ $1 != --allow ]]; then
  printf 'Usage: %s --allow NAME [NAME ...] -- <command> [arguments ...]\n' "$0" >&2
  exit 2
fi

command -v sops >/dev/null 2>&1 || { printf 'sops is not installed.\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'jq is not installed.\n' >&2; exit 1; }

if [[ ! -r "${secrets_file}" ]]; then
  printf 'Encrypted secrets file is missing: %s\n' "${secrets_file}" >&2
  exit 2
fi
if ! grep -q '^sops:' "${secrets_file}"; then
  printf 'Refusing to load a secrets file without SOPS metadata: %s\n' "${secrets_file}" >&2
  exit 2
fi

shift
allowed_names=()
declare -A requested_names=()
while (($# > 0)) && [[ $1 != -- ]]; do
  if [[ ! $1 =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    printf 'Invalid environment variable name in allowlist: %s\n' "$1" >&2
    exit 2
  fi
  if [[ -n ${requested_names[$1]+present} ]]; then
    printf 'Duplicate environment variable in allowlist: %s\n' "$1" >&2
    exit 2
  fi
  allowed_names+=("$1")
  requested_names["$1"]=1
  shift
done
if (($# == 0)) || [[ $1 != -- ]]; then
  printf 'The allowlist must end with --.\n' >&2
  exit 2
fi
shift
if (($# == 0)); then
  printf 'A command is required after --.\n' >&2
  exit 2
fi

# Prevent parent-shell values from bypassing the file-specific allowlist. This
# list is intentionally repository-wide; newly introduced secret names must be
# added here and to the relevant Make target.
known_secret_names=(
  HCLOUD_TOKEN
  DESEC_API_TOKEN
  MAIL_POSTGRES_PASSWORD
  STALWART_DESEC_API_TOKEN
  STALWART_CONFIG_API_TOKEN
)
unset "${known_secret_names[@]}" "${allowed_names[@]}"

declare -A selected_values=()
while IFS= read -r -d '' name && IFS= read -r -d '' value; do
  if [[ ! ${name} =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    printf 'SOPS document contains an invalid environment variable name.\n' >&2
    exit 1
  fi
  if [[ -n ${requested_names[$name]+present} ]]; then
    selected_values["${name}"]=${value}
  fi
done < <(
  sops decrypt --output-type json "${secrets_file}" |
    jq -j '
      if type != "object" or any(to_entries[]; (.value | type) != "string") then
        error("the decrypted SOPS document must be a flat string map")
      else
        to_entries[] | .key, "\u0000", .value, "\u0000"
      end
    '
)
decrypt_pipeline_pid=$!
if wait "${decrypt_pipeline_pid}"; then
  :
else
  decrypt_pipeline_status=$?
  unset selected_values
  printf 'SOPS decryption pipeline failed with status %s.\n' "${decrypt_pipeline_status}" >&2
  exit "${decrypt_pipeline_status}"
fi

for name in "${allowed_names[@]}"; do
  if [[ -z ${selected_values[$name]+present} ]]; then
    printf 'Required secret is missing from %s: %s\n' "${secrets_file}" "${name}" >&2
    exit 1
  fi
  printf -v "${name}" '%s' "${selected_values[$name]}"
  export "${name}"
done
unset selected_values

exec "$@"
