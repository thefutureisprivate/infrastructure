#!/usr/bin/env bash
set -euo pipefail

sops_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${sops_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}
tf_dir=${TF_DIR:-OpenTofu}
mail_secrets_name=${SOPS_MAIL_FILE:-SOPS/mail.sops.yaml}

case "${tf_dir}" in
  /*) tf_path=${tf_dir} ;;
  *) tf_path="${repo_root}/${tf_dir}" ;;
esac
case "${mail_secrets_name}" in
  /*) mail_secrets_file=${mail_secrets_name} ;;
  *) mail_secrets_file="${repo_root}/${mail_secrets_name}" ;;
esac

command -v "${tofu_bin}" >/dev/null 2>&1 || { printf '%s is not installed.\n' "${tofu_bin}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'jq is not installed.\n' >&2; exit 1; }
command -v sops >/dev/null 2>&1 || { printf 'sops is not installed.\n' >&2; exit 1; }

if [[ ! -r ${mail_secrets_file} ]] || ! grep -q '^sops:' "${mail_secrets_file}"; then
  printf 'Encrypted mail secrets are missing or invalid: %s\n' "${mail_secrets_file}" >&2
  exit 2
fi

storage_json=$("${tofu_bin}" -chdir="${tf_path}" output -json mail_backup_storage)
if printf '%s' "${storage_json}" | jq -e '.runtime_enabled == false' >/dev/null; then
  unset storage_json
  printf 'Mail backups are disabled; no generated backup credentials were synchronized.\n'
  exit 0
fi
printf '%s' "${storage_json}" | jq -e '.runtime_enabled == true' >/dev/null || {
  unset storage_json
  printf 'OpenTofu returned an invalid mail backup runtime status.\n' >&2
  exit 1
}
unset storage_json
credentials_json=$("${tofu_bin}" -chdir="${tf_path}" output -json mail_backup_runtime_credentials)

printf '%s' "${credentials_json}" | jq -e '
  type == "object"
  and ([
    .b2_pgbackrest_key_id,
    .b2_pgbackrest_key,
    .b2_archive_key_id,
    .b2_archive_key,
    .scaleway_access_key,
    .scaleway_secret_key
  ] | all(type == "string" and length >= 16))
' >/dev/null || {
  printf 'OpenTofu returned incomplete backup runtime credentials.\n' >&2
  exit 1
}

hetzner_access_key=${MINIO_USER:-}
hetzner_secret_key=${MINIO_PASSWORD:-}
if ((${#hetzner_access_key} < 16)) || ((${#hetzner_secret_key} < 16)); then
  printf 'Hetzner backup credentials are missing or invalid.\n' >&2
  exit 1
fi
jq -cn --arg value "${hetzner_access_key}" '$value' \
  | sops set --value-stdin "${mail_secrets_file}" \
      '["MAIL_BACKUP_HETZNER_ACCESS_KEY"]'
jq -cn --arg value "${hetzner_secret_key}" '$value' \
  | sops set --value-stdin "${mail_secrets_file}" \
      '["MAIL_BACKUP_HETZNER_SECRET_KEY"]'
unset hetzner_access_key hetzner_secret_key

while IFS=$'\t' read -r output_name sops_name; do
  printf '%s' "${credentials_json}" \
    | jq -ce --arg name "${output_name}" '.[$name]' \
    | sops set --value-stdin "${mail_secrets_file}" "[\"${sops_name}\"]"
done <<'EOF'
b2_pgbackrest_key_id	PGBACKREST_REPO2_S3_KEY
b2_pgbackrest_key	PGBACKREST_REPO2_S3_KEY_SECRET
b2_archive_key_id	MAIL_BACKUP_B2_ACCESS_KEY
b2_archive_key	MAIL_BACKUP_B2_SECRET_KEY
scaleway_access_key	MAIL_BACKUP_SCALEWAY_ACCESS_KEY
scaleway_secret_key	MAIL_BACKUP_SCALEWAY_SECRET_KEY
EOF
unset credentials_json

for retired_name in PGBACKREST_REPO1_S3_KEY PGBACKREST_REPO1_S3_KEY_SECRET; do
  sops unset --idempotent "${mail_secrets_file}" "[\"${retired_name}\"]"
done

printf 'Stored Hetzner, generated B2, and Scaleway runtime credentials in %s.\n' \
  "${mail_secrets_file}"
