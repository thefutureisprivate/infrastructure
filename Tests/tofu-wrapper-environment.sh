#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

SCW_ACCESS_KEY='scaleway-access-key' \
SCW_SECRET_KEY='scaleway-secret-key' \
MINIO_USER='hetzner-access-key' \
MINIO_PASSWORD='hetzner-secret-key' \
AWS_ACCESS_KEY_ID='unrelated-access-key' \
AWS_SECRET_ACCESS_KEY='unrelated-secret-key' \
AWS_SESSION_TOKEN='unrelated-session-token' \
TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
TOFU_BINARY="${repo_root}/Tests/mocks/tofu-environment" \
  "${repo_root}/Scripts/tofu.sh"

if TOFU_STATE_PASSPHRASE='replace-with-at-least-32-random-characters-kept-offline-too' \
  TOFU_BINARY="${repo_root}/Tests/mocks/tofu-environment" \
  "${repo_root}/Scripts/tofu.sh" >/dev/null 2>&1; then
  printf 'OpenTofu accepted the published state-passphrase placeholder.\n' >&2
  exit 1
fi
grep -Fq -- 'generated_state_passphrase=$(openssl rand -base64 48)' \
  "${repo_root}/SOPS/init.sh"

printf 'OpenTofu backend credential isolation: OK\n'
