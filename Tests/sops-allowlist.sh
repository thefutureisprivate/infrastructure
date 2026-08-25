#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sops-allowlist.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

printf '%s\n' 'sops:' >"${test_root}/secrets.sops.yaml"
chmod 0600 "${test_root}/secrets.sops.yaml"

PATH="${repo_root}/Tests/mocks:${PATH}" \
SOPS_SECRETS_FILE="${test_root}/secrets.sops.yaml" \
HCLOUD_TOKEN="inherited-cloud-token" \
DESEC_API_TOKEN="inherited-dns-token" \
MAIL_POSTGRES_PASSWORD="inherited-mail-token" \
  bash "${repo_root}/SOPS/exec-env.sh" --allow HCLOUD_TOKEN -- \
  bash -c '
    [[ ${HCLOUD_TOKEN:-} == selected-cloud-token ]]
    [[ -z ${DESEC_API_TOKEN+x} ]]
    [[ -z ${MAIL_POSTGRES_PASSWORD+x} ]]
    [[ -z ${STALWART_DESEC_API_TOKEN+x} ]]
    [[ -z ${STALWART_CONFIG_API_TOKEN+x} ]]
  '

if PATH="${repo_root}/Tests/mocks:${PATH}" \
  SOPS_SECRETS_FILE="${test_root}/secrets.sops.yaml" \
  bash "${repo_root}/SOPS/exec-env.sh" --allow MAIL_POSTGRES_PASSWORD -- true; then
  printf '%s\n' "A missing allowlisted secret did not fail closed." >&2
  exit 1
fi

# A decryptor can emit complete-looking JSON before detecting an integrity or
# I/O failure. The wrapper must propagate that late failure and never launch the
# requested command with the unauthenticated values.
if PATH="${repo_root}/Tests/mocks:${PATH}" \
  SOPS_SECRETS_FILE="${test_root}/secrets.sops.yaml" \
  MOCK_SOPS_EXIT=7 \
  bash "${repo_root}/SOPS/exec-env.sh" --allow HCLOUD_TOKEN -- \
  touch "${test_root}/decrypt-failure-command-ran"; then
  printf '%s\n' "A failing SOPS decrypt pipeline returned success." >&2
  exit 1
fi
if [[ -e ${test_root}/decrypt-failure-command-ran ]]; then
  printf '%s\n' "A command ran after the SOPS decrypt pipeline failed." >&2
  exit 1
fi

printf '%s\n' "SOPS environment allowlist: OK"
