#!/usr/bin/env bash
set -euo pipefail

sops_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
secrets_file=${SOPS_SECRETS_FILE:-"${sops_dir}/infrastructure.sops.yaml"}

if (( $# < 4 )) || [[ $1 != --allow ]]; then
  printf 'Usage: %s --allow NAME [NAME ...] [--optional NAME ...] -- <command> [arguments ...]\n' "$0" >&2
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
required_names=()
optional_names=()
declare -A requested_names=()
selection=required
while (($# > 0)) && [[ $1 != -- ]]; do
  if [[ $1 == --optional ]]; then
    if [[ ${selection} == optional ]]; then
      printf 'The optional allowlist may be declared only once.\n' >&2
      exit 2
    fi
    selection=optional
    shift
    continue
  fi
  if [[ ! $1 =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    printf 'Invalid environment variable name in allowlist: %s\n' "$1" >&2
    exit 2
  fi
  if [[ -n ${requested_names[$1]+present} ]]; then
    printf 'Duplicate environment variable in allowlist: %s\n' "$1" >&2
    exit 2
  fi
  allowed_names+=("$1")
  if [[ ${selection} == required ]]; then
    required_names+=("$1")
  else
    optional_names+=("$1")
  fi
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
  MINIO_USER
  MINIO_PASSWORD
  B2_APPLICATION_KEY_ID
  B2_APPLICATION_KEY
  SCW_ACCESS_KEY
  SCW_SECRET_KEY
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  TOFU_STATE_PASSPHRASE
  MAIL_POSTGRES_ADMIN_PASSWORD
  MAIL_POSTGRES_PASSWORD
  MAIL_POSTGRES_DUMP_PASSWORD
  STALWART_DESEC_API_TOKEN
  STALWART_CONFIG_API_TOKEN
  PGBACKREST_REPO1_S3_KEY
  PGBACKREST_REPO1_S3_KEY_SECRET
  PGBACKREST_REPO1_CIPHER_PASS
  PGBACKREST_REPO2_S3_KEY
  PGBACKREST_REPO2_S3_KEY_SECRET
  PGBACKREST_REPO2_CIPHER_PASS
  MAIL_BACKUP_SCALEWAY_ACCESS_KEY
  MAIL_BACKUP_SCALEWAY_SECRET_KEY
  MAIL_BACKUP_HETZNER_ACCESS_KEY
  MAIL_BACKUP_HETZNER_SECRET_KEY
  MAIL_BACKUP_B2_ACCESS_KEY
  MAIL_BACKUP_B2_SECRET_KEY
  MAIL_BACKUP_SIGNING_PRIVATE_KEY
  MAIL_BACKUP_SIGNING_PUBLIC_KEY
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

for name in "${required_names[@]}"; do
  if [[ -z ${selected_values[$name]+present} ]]; then
    printf 'Required secret is missing from %s: %s\n' "${secrets_file}" "${name}" >&2
    exit 1
  fi
  printf -v "${name}" '%s' "${selected_values[$name]}"
  export "${name}"
done
for name in "${optional_names[@]}"; do
  if [[ -n ${selected_values[$name]+present} ]]; then
    printf -v "${name}" '%s' "${selected_values[$name]}"
    export "${name}"
  fi
done
unset selected_values

exec "$@"
