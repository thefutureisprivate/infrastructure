#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_directory=${TF_DIR:-OpenTofu}
tofu_binary=${TOFU_BINARY:-tofu}
sops_binary=${SOPS_BINARY:-sops}
sops_config=${SOPS_CONFIG_FILE:-"${repo_root}/SOPS/config.yaml"}
snapshot_root=${TOFU_LOCAL_STATE_DIR:-}
temporary_snapshot=''
umask 077

cleanup() {
  if [[ -n ${temporary_snapshot} && -f ${temporary_snapshot} && \
        ${temporary_snapshot} == "${snapshot_root}/.state-snapshot."* ]]; then
    rm -f -- "${temporary_snapshot}"
  fi
}
trap cleanup EXIT HUP INT TERM

for command_name in date install jq mktemp "${sops_binary}" "${tofu_binary}"; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required to create the local encrypted state snapshot.\n' \
      "${command_name}" >&2
    exit 1
  }
done

case ${tofu_directory} in
  /*) tofu_path=${tofu_directory} ;;
  *) tofu_path="${repo_root}/${tofu_directory}" ;;
esac
if [[ ! -d ${tofu_path} ]]; then
  printf 'OpenTofu working directory does not exist: %s\n' "${tofu_path}" >&2
  exit 2
fi
if [[ -z ${snapshot_root} ]]; then
  snapshot_root="${tofu_path}/state-snapshots"
fi
if [[ ! -r ${sops_config} ]]; then
  printf 'SOPS recipient configuration is not readable: %s\n' "${sops_config}" >&2
  exit 2
fi

install -d -m 0700 -- "${snapshot_root}"
snapshot_root=$(cd -- "${snapshot_root}" && pwd -P)
temporary_snapshot=$(mktemp "${snapshot_root}/.state-snapshot.XXXXXXXX")
timestamp=$(date -u +'%Y%m%dT%H%M%S%NZ')
snapshot_file="${snapshot_root}/infrastructure-${timestamp}.sops.json"

if [[ -e ${snapshot_file} ]]; then
  printf 'Refusing to overwrite an existing local state snapshot: %s\n' \
    "${snapshot_file}" >&2
  exit 1
fi

# `state pull` emits decrypted JSON even when the backend object uses native
# OpenTofu encryption. Keep that JSON in a pipe and immediately wrap it for the
# workstation's age recovery identity; plaintext is never persisted locally.
TOFU_BINARY="${tofu_binary}" "${repo_root}/Scripts/tofu.sh" \
  -chdir="${tofu_path}" state pull |
  (
    cd -- "${repo_root}/SOPS"
    "${sops_binary}" --config "${sops_config}" encrypt \
      --filename-override infrastructure.sops.yaml \
      --input-type json \
      --output-type json \
      --encrypted-regex '.*'
  ) >"${temporary_snapshot}"

if ! jq -e '
  def encrypted_scalars:
    if type == "object" then
      all(to_entries[]; .value | encrypted_scalars)
    elif type == "array" then
      all(.[]; encrypted_scalars)
    else
      type == "null"
      or (type == "string"
          and (length == 0 or startswith("ENC[AES256_GCM,")))
    end;
  (.sops.age | type == "array" and length > 0)
  and (.sops.mac | type == "string" and startswith("ENC[AES256_GCM,"))
  and (.sops.encrypted_regex == ".*")
  and (.sops.unencrypted_suffix == null)
  and (del(.sops) | encrypted_scalars)
' "${temporary_snapshot}" >/dev/null; then
  printf '%s\n' \
    'Refusing the local state snapshot because SOPS left a non-empty state value unencrypted.' \
    >&2
  exit 1
fi

chmod 0600 "${temporary_snapshot}"
mv -- "${temporary_snapshot}" "${snapshot_file}"
temporary_snapshot=''
trap - EXIT HUP INT TERM
printf 'Encrypted local OpenTofu recovery snapshot: %s\n' "${snapshot_file}"
