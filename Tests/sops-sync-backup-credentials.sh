#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sops-sync-backup.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

printf '%s\n' 'sops:' >"${test_root}/mail.sops.yaml"
: >"${test_root}/sops.log"

PATH="${repo_root}/Tests/mocks/backup-credentials:${PATH}" \
TOFU=tofu \
TF_DIR="${test_root}" \
SOPS_MAIL_FILE="${test_root}/mail.sops.yaml" \
MOCK_SOPS_LOG="${test_root}/sops.log" \
MINIO_USER='hetzner-key-no-newline' \
MINIO_PASSWORD='hetzner-secret-ends-in-equals==' \
  bash "${repo_root}/SOPS/sync-backup-credentials.sh" >/dev/null

jq -e -s '
  length == 10
  and . == [
    {"path":"[\"MAIL_BACKUP_HETZNER_ACCESS_KEY\"]","value":"hetzner-key-no-newline"},
    {"path":"[\"MAIL_BACKUP_HETZNER_SECRET_KEY\"]","value":"hetzner-secret-ends-in-equals=="},
    {"path":"[\"PGBACKREST_REPO2_S3_KEY\"]","value":"b2-id-0123456789"},
    {"path":"[\"PGBACKREST_REPO2_S3_KEY_SECRET\"]","value":"b2-secret-No-Newline+12345"},
    {"path":"[\"MAIL_BACKUP_B2_ACCESS_KEY\"]","value":"b2-archive-012345"},
    {"path":"[\"MAIL_BACKUP_B2_SECRET_KEY\"]","value":"b2-archive-secret+12345"},
    {"path":"[\"MAIL_BACKUP_SCALEWAY_ACCESS_KEY\"]","value":"scw-access-012345"},
    {"path":"[\"MAIL_BACKUP_SCALEWAY_SECRET_KEY\"]","value":"scw-secret-ends-in-equals=="},
    {"path":"[\"PGBACKREST_REPO1_S3_KEY\"]","unset":true},
    {"path":"[\"PGBACKREST_REPO1_S3_KEY_SECRET\"]","unset":true}
  ]
' "${test_root}/sops.log" >/dev/null

: >"${test_root}/sops.log"
PATH="${repo_root}/Tests/mocks/backup-credentials:${PATH}" \
TOFU=tofu \
TF_DIR="${test_root}" \
SOPS_MAIL_FILE="${test_root}/mail.sops.yaml" \
MOCK_SOPS_LOG="${test_root}/sops.log" \
MOCK_BACKUP_RUNTIME_ENABLED=false \
MOCK_BACKUP_CREDENTIALS=missing \
  bash "${repo_root}/SOPS/sync-backup-credentials.sh" >/dev/null
[[ ! -s ${test_root}/sops.log ]]

if env -u MINIO_USER -u MINIO_PASSWORD \
  PATH="${repo_root}/Tests/mocks/backup-credentials:${PATH}" \
  TOFU=tofu \
  TF_DIR="${test_root}" \
  SOPS_MAIL_FILE="${test_root}/mail.sops.yaml" \
  MOCK_SOPS_LOG="${test_root}/sops.log" \
  bash "${repo_root}/SOPS/sync-backup-credentials.sh" >/dev/null 2>&1; then
  printf 'Enabled backup runtime accepted missing Hetzner credentials.\n' >&2
  exit 1
fi
[[ ! -s ${test_root}/sops.log ]]

if PATH="${repo_root}/Tests/mocks/backup-credentials:${PATH}" \
  TOFU=tofu \
  TF_DIR="${test_root}" \
  SOPS_MAIL_FILE="${test_root}/mail.sops.yaml" \
  MOCK_SOPS_LOG="${test_root}/sops.log" \
  MINIO_USER='hetzner-key-no-newline' \
  MINIO_PASSWORD='hetzner-secret-ends-in-equals==' \
  MOCK_BACKUP_CREDENTIALS=incomplete \
  bash "${repo_root}/SOPS/sync-backup-credentials.sh" >/dev/null 2>&1; then
  printf 'Incomplete generated backup credentials were accepted.\n' >&2
  exit 1
fi
[[ ! -s ${test_root}/sops.log ]]

if PATH="${repo_root}/Tests/mocks/backup-credentials:${PATH}" \
  TOFU=tofu \
  TF_DIR="${test_root}" \
  SOPS_MAIL_FILE="${test_root}/mail.sops.yaml" \
  MOCK_SOPS_LOG="${test_root}/sops.log" \
  MINIO_USER='hetzner-key-no-newline' \
  MINIO_PASSWORD='hetzner-secret-ends-in-equals==' \
  MOCK_BACKUP_CREDENTIALS=missing \
  bash "${repo_root}/SOPS/sync-backup-credentials.sh" >/dev/null 2>&1; then
  printf 'Enabled backup runtime accepted a missing credential output.\n' >&2
  exit 1
fi
[[ ! -s ${test_root}/sops.log ]]

printf 'SOPS backup credential byte preservation: OK\n'
