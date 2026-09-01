#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/tofu-state-snapshot.XXXXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM
snapshot_root="${test_root}/snapshots"
mock_root="${repo_root}/Tests/mocks/state-snapshot"
backend_example="${repo_root}/OpenTofu/backend.hcl.example"
makefile="${repo_root}/Makefile"

grep -Fqx 'region = "fr-par"' "${backend_example}"
grep -Fqx '  s3 = "https://s3.fr-par.scw.cloud"' "${backend_example}"
if grep -Fq 'nl-ams' "${backend_example}"; then
  printf 'The backend example drifted from the enforced Paris bootstrap region.\n' >&2
  exit 1
fi

apply_line=$(grep -nF 'apply main.tfplan' "${makefile}" | cut -d: -f1)
snapshot_line=$(grep -nF '@$(MAKE) tofu-state-snapshot' "${makefile}" | cut -d: -f1)
desec_sync_line=$(grep -nF '@$(MAKE) sops-mail-sync-desec' "${makefile}" | cut -d: -f1)
backup_sync_line=$(grep -nF '@$(MAKE) sops-mail-sync-backup' "${makefile}" | cut -d: -f1)
if [[ -z ${apply_line} || -z ${snapshot_line} || -z ${desec_sync_line} ||
      -z ${backup_sync_line} ]] ||
   ! ((apply_line < snapshot_line &&
       snapshot_line < desec_sync_line &&
       desec_sync_line < backup_sync_line)); then
  printf 'A successful OpenTofu apply must snapshot state before credential synchronization.\n' >&2
  exit 1
fi

install -d -m 0700 "${test_root}/source"
printf '%s\n' 'creation_rules: []' >"${test_root}/config.yaml"

TOFU_BINARY="${mock_root}/tofu" \
SOPS_BINARY="${mock_root}/sops" \
SOPS_CONFIG_FILE="${test_root}/config.yaml" \
TF_DIR="${test_root}/source" \
TOFU_LOCAL_STATE_DIR="${snapshot_root}" \
TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
  "${repo_root}/Scripts/snapshot-tofu-state.sh" >/dev/null

mapfile -t snapshots < <(find "${snapshot_root}" -maxdepth 1 -type f \
  -name 'infrastructure-*.sops.json' -print)
if ((${#snapshots[@]} != 1)); then
  printf 'Expected one encrypted local state snapshot, found %s.\n' \
    "${#snapshots[@]}" >&2
  exit 1
fi
snapshot=${snapshots[0]}
[[ $(stat -c '%a' "${snapshot}") == 600 ]]
if grep -Eq 'top-secret-output|must-also-be-encrypted' "${snapshot}"; then
  printf 'The local state snapshot retained a plaintext state value.\n' >&2
  exit 1
fi
jq -e '
  (.sops.age | length == 1)
  and (.sops.mac | startswith("ENC[AES256_GCM,"))
  and (.sops.encrypted_regex == ".*")
  and (.sops.unencrypted_suffix == null)
  and (.version | startswith("ENC[AES256_GCM,"))
  and (.outputs.credential.value | startswith("ENC[AES256_GCM,"))
  and (.resources[0].instances[0].attributes.provider_unencrypted
       | startswith("ENC[AES256_GCM,"))
  and (.resources[0].instances[0].attributes.optional_empty_value == "")
' "${snapshot}" >/dev/null

TOFU_BINARY="${mock_root}/tofu" \
SOPS_BINARY="${mock_root}/sops" \
SOPS_CONFIG_FILE="${test_root}/config.yaml" \
TF_DIR="${test_root}/source" \
TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
  "${repo_root}/Scripts/snapshot-tofu-state.sh" >/dev/null
mapfile -t default_snapshots < <(find "${test_root}/source/state-snapshots" \
  -maxdepth 1 -type f -name 'infrastructure-*.sops.json' -print)
if ((${#default_snapshots[@]} != 1)); then
  printf 'The default snapshot was not written inside the OpenTofu directory.\n' >&2
  exit 1
fi

if TOFU_BINARY="${mock_root}/tofu" \
  SOPS_BINARY="${mock_root}/sops" \
  SOPS_CONFIG_FILE="${test_root}/config.yaml" \
  TF_DIR="${test_root}/source" \
  TOFU_LOCAL_STATE_DIR="${snapshot_root}" \
  TOFU_STATE_PASSPHRASE='test-only-state-encryption-passphrase-32-characters' \
  MOCK_SOPS_EXIT=7 \
    "${repo_root}/Scripts/snapshot-tofu-state.sh" >/dev/null 2>&1; then
  printf 'A failed local state encryption pipeline returned success.\n' >&2
  exit 1
fi
if find "${snapshot_root}" -maxdepth 1 -type f -name '.state-snapshot.*' \
  | grep -q .; then
  printf 'A failed local state snapshot left a partial file behind.\n' >&2
  exit 1
fi

printf 'Encrypted local OpenTofu state snapshots: OK\n'
