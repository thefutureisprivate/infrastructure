#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tofu-state-restore.XXXXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM
snapshot_root="${test_root}/OpenTofu/state-snapshots"
mock_root="${repo_root}/Tests/mocks/state-restore"
snapshot="${snapshot_root}/infrastructure-20260828T000000000000000Z.sops.json"

install -d -m 0700 "${snapshot_root}"
printf '%s\n' '{
  "version": "ENC[AES256_GCM,data:test,iv:test,tag:test,type:int]",
  "serial": "ENC[AES256_GCM,data:test,iv:test,tag:test,type:int]",
  "lineage": "ENC[AES256_GCM,data:test,iv:test,tag:test,type:str]",
  "resources": ["ENC[AES256_GCM,data:test,iv:test,tag:test,type:str]"],
  "sops": {
    "age": [{"recipient": "age1test", "enc": "test"}],
    "encrypted_regex": ".*",
    "mac": "ENC[AES256_GCM,data:test,iv:test,tag:test,type:str]",
    "unencrypted_suffix": null,
    "version": "test"
  }
}' >"${snapshot}"
chmod 0600 "${snapshot}"

TOFU_BINARY="${mock_root}/tofu" \
SOPS_BINARY="${mock_root}/sops" \
TF_DIR="${test_root}/OpenTofu" \
TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
  "${repo_root}/Scripts/restore-tofu-state-snapshot.sh" "${snapshot}" >/dev/null

outside_snapshot="${test_root}/outside.sops.json"
cp -- "${snapshot}" "${outside_snapshot}"
if TOFU_BINARY="${mock_root}/tofu" \
  SOPS_BINARY="${mock_root}/sops" \
  TF_DIR="${test_root}/OpenTofu" \
  TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
    "${repo_root}/Scripts/restore-tofu-state-snapshot.sh" \
      "${outside_snapshot}" >/dev/null 2>&1; then
  printf 'State restore accepted a snapshot outside the dedicated directory.\n' >&2
  exit 1
fi

snapshot_symlink="${snapshot_root}/infrastructure-symlink.sops.json"
ln -s -- "${snapshot}" "${snapshot_symlink}"
if TOFU_BINARY="${mock_root}/tofu" \
  SOPS_BINARY="${mock_root}/sops" \
  TF_DIR="${test_root}/OpenTofu" \
  TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
    "${repo_root}/Scripts/restore-tofu-state-snapshot.sh" \
      "${snapshot_symlink}" >/dev/null 2>&1; then
  printf 'State restore accepted a symlinked snapshot.\n' >&2
  exit 1
fi

printf 'Encrypted local OpenTofu state restore: OK\n'
