#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tofu-mail-backup-flags.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

if ! command -v "${tofu_bin}" >/dev/null 2>&1; then
  printf 'OpenTofu backup flag validation: skipped (%s unavailable)\n' "${tofu_bin}"
  exit 0
fi

sed -n \
  '/^variable "mail_backup_storage_enabled" {/,/^}/p' \
  "${repo_root}/OpenTofu/variables.tf" >"${test_root}/main.tf"
sed -n \
  '/^variable "mail_backup_enabled" {/,/^}/p' \
  "${repo_root}/OpenTofu/variables.tf" >>"${test_root}/main.tf"
sed -n \
  '/^variable "mail_backup_age_recipient" {/,/^}/p' \
  "${repo_root}/OpenTofu/variables.tf" >>"${test_root}/main.tf"

if [[ $(grep -Fc 'variable "mail_backup_' "${test_root}/main.tf") -ne 3 ]]; then
  printf 'Could not isolate the mail backup lifecycle variables for testing.\n' >&2
  exit 1
fi

"${tofu_bin}" -chdir="${test_root}" init -backend=false -input=false >/dev/null

for flags in 'false false' 'true false' 'true true'; do
  read -r storage_enabled runtime_enabled <<<"${flags}"
  "${tofu_bin}" -chdir="${test_root}" plan \
    -input=false \
    -lock=false \
    -refresh=false \
    -var="mail_backup_storage_enabled=${storage_enabled}" \
    -var="mail_backup_enabled=${runtime_enabled}" \
    -var='mail_backup_age_recipient=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' >/dev/null
done

if "${tofu_bin}" -chdir="${test_root}" plan \
  -input=false \
  -lock=false \
  -refresh=false \
  -var='mail_backup_storage_enabled=false' \
  -var='mail_backup_enabled=true' \
  -var='mail_backup_age_recipient=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq' \
  >"${test_root}/invalid-plan.log" 2>&1; then
  printf 'OpenTofu accepted backup runtime enablement without durable storage.\n' >&2
  exit 1
fi
grep -Fq \
  'mail_backup_enabled requires mail_backup_storage_enabled and' \
  "${test_root}/invalid-plan.log"

if "${tofu_bin}" -chdir="${test_root}" plan \
  -input=false \
  -lock=false \
  -refresh=false \
  -var='mail_backup_storage_enabled=true' \
  -var='mail_backup_enabled=true' \
  -var='mail_backup_age_recipient=' >"${test_root}/invalid-age.log" 2>&1; then
  printf 'OpenTofu accepted backup runtime enablement without an age recipient.\n' >&2
  exit 1
fi
grep -Fq 'mail_backup_age_recipient' "${test_root}/invalid-age.log"

printf 'OpenTofu backup flag validation: OK\n'
