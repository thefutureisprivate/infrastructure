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

if [[ ! -r "${mail_secrets_file}" ]]; then
  printf 'Encrypted mail secrets are missing: %s\n' "${mail_secrets_file}" >&2
  exit 2
fi
if ! grep -q '^sops:' "${mail_secrets_file}"; then
  printf 'Refusing to update a secrets file without SOPS metadata: %s\n' "${mail_secrets_file}" >&2
  exit 2
fi

stalwart_desec_api_token=$("${tofu_bin}" -chdir="${tf_path}" output -raw stalwart_desec_api_token)
if (( ${#stalwart_desec_api_token} < 16 )); then
  printf 'OpenTofu returned an invalid Stalwart deSEC token.\n' >&2
  exit 1
fi

printf '%s' "${stalwart_desec_api_token}" \
  | jq -Rs . \
  | sops set --value-stdin "${mail_secrets_file}" '["STALWART_DESEC_API_TOKEN"]'
unset stalwart_desec_api_token

printf 'Stored the generated Stalwart deSEC token in %s.\n' "${mail_secrets_file}"
