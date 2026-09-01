#!/usr/bin/env bash
set -euo pipefail

sops_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${sops_dir}/.." && pwd)
output_name=${1:-SOPS/infrastructure.sops.yaml}
template_name=${2:-SOPS/infrastructure.example.yaml}
config_file=${SOPS_CONFIG_FILE:-"${sops_dir}/config.yaml"}

case "${output_name}" in
  /*) output_file=${output_name} ;;
  *) output_file="${repo_root}/${output_name}" ;;
esac
case "${template_name}" in
  /*) template_file=${template_name} ;;
  *) template_file="${repo_root}/${template_name}" ;;
esac

if [[ "${output_file}" != "${sops_dir}/"* ]]; then
  printf 'The encrypted output must be inside %s.\n' "${sops_dir}" >&2
  exit 2
fi
filename_override=$(basename -- "${output_file}")

command -v sops >/dev/null 2>&1 || { printf 'sops is not installed.\n' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { printf 'openssl is not installed.\n' >&2; exit 1; }

if [[ ! -r "${config_file}" ]]; then
  printf 'Create SOPS/config.yaml from SOPS/config.example.yaml and set your public age recipient first.\n' >&2
  exit 2
fi
if [[ ! -r "${template_file}" ]]; then
  printf 'SOPS template is missing: %s\n' "${template_file}" >&2
  exit 2
fi
if grep -q 'age1replace_with_your_public_recipient' "${config_file}"; then
  printf 'Replace the placeholder age recipient in SOPS/config.yaml first.\n' >&2
  exit 2
fi
if [[ -e "${output_file}" ]]; then
  printf 'Refusing to overwrite existing secrets file: %s\n' "${output_file}" >&2
  exit 2
fi

temporary_output=$(mktemp "${sops_dir}/.sops.XXXXXX")
trap 'rm -f -- "${temporary_output}"' EXIT HUP INT TERM

generated_state_passphrase=$(openssl rand -base64 48)
if [[ ! ${generated_state_passphrase} =~ ^[A-Za-z0-9+/=]{64,}$ ]]; then
  printf 'OpenSSL did not generate the expected state passphrase.\n' >&2
  exit 1
fi
(cd "${sops_dir}" && \
  sed "s#replace-with-at-least-32-random-characters-kept-offline-too#${generated_state_passphrase}#" \
    "${template_file}" | \
  sops --config "${config_file}" --encrypt \
    --filename-override "${filename_override}" >"${temporary_output}")
unset generated_state_passphrase
grep -q '^sops:' "${temporary_output}" || { printf 'SOPS output has no metadata block.\n' >&2; exit 1; }
chmod 0600 "${temporary_output}"
mv -f -- "${temporary_output}" "${output_file}"
trap - EXIT HUP INT TERM
printf 'Created %s. Edit it with sops before use.\n' "${output_file}"
