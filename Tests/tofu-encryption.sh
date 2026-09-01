#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}
passphrase='test-only-state-encryption-passphrase-32-characters'

command -v "${tofu_bin}" >/dev/null 2>&1 || {
  printf '%s is not installed.\n' "${tofu_bin}" >&2
  exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/tofu-encryption.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM
encrypted_root="${test_root}/encrypted"
plaintext_root="${test_root}/plaintext"
install -d -- "${encrypted_root}" "${plaintext_root}"
cp "${script_dir}/fixtures/tofu-encryption-main.tf" "${encrypted_root}/main.tf"
cp "${script_dir}/fixtures/tofu-encryption-main.tf" "${plaintext_root}/main.tf"
cp "${script_dir}/fixtures/tofu-plaintext-state.json" \
  "${plaintext_root}/terraform.tfstate"

if TOFU_BINARY="${tofu_bin}" TOFU_STATE_PASSPHRASE="${passphrase}" \
  "${repo_root}/Scripts/tofu.sh" -chdir="${plaintext_root}" state list \
  >"${test_root}/normal.stdout" 2>"${test_root}/normal.stderr"; then
  printf 'Normal OpenTofu mode unexpectedly accepted plaintext state.\n' >&2
  exit 1
fi
grep -Fq 'Refusing OpenTofu while plaintext state or plan artifacts remain' \
  "${test_root}/normal.stderr"

TOFU_BINARY="${tofu_bin}" TOFU_STATE_PASSPHRASE="${passphrase}" \
  "${repo_root}/Scripts/tofu.sh" -chdir="${encrypted_root}" \
  apply -auto-approve >/dev/null

jq -e '
  .encryption_version == "v0"
  and (.encrypted_data | type == "string" and length > 32)
  and (.meta["infrastructure-state-v1"] | type == "string" and length > 32)
' "${encrypted_root}/terraform.tfstate" >/dev/null

TOFU_BINARY="${tofu_bin}" TOFU_STATE_PASSPHRASE="${passphrase}" \
  "${repo_root}/Scripts/tofu.sh" -chdir="${encrypted_root}" state list >/dev/null

printf 'OpenTofu encryption enforcement: OK\n'
