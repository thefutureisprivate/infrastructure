#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_directory=${TF_DIR:-OpenTofu}
tofu_binary=${TOFU_BINARY:-tofu}
sops_binary=${SOPS_BINARY:-sops}
snapshot=${1:-}

for command_name in jq realpath "${sops_binary}" "${tofu_binary}"; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required to restore an encrypted state snapshot.\n' \
      "${command_name}" >&2
    exit 1
  }
done

case ${tofu_directory} in
  /*) tofu_path=${tofu_directory} ;;
  *) tofu_path="${repo_root}/${tofu_directory}" ;;
esac
snapshot_root="${tofu_path}/state-snapshots"
if [[ ! -d ${snapshot_root} ]]; then
  printf 'State snapshot directory does not exist: %s\n' "${snapshot_root}" >&2
  exit 2
fi
if [[ -z ${snapshot} ]]; then
  printf 'Pass one exact encrypted state snapshot as the first argument.\n' >&2
  exit 2
fi
case ${snapshot} in
  /*) ;;
  *) snapshot="${repo_root}/${snapshot}" ;;
esac
if [[ ! -f ${snapshot} || -L ${snapshot} ]]; then
  printf 'State snapshot must be a regular, non-symlink file.\n' >&2
  exit 2
fi

snapshot_root=$(realpath -e -- "${snapshot_root}")
snapshot=$(realpath -e -- "${snapshot}")
case ${snapshot} in
  "${snapshot_root}"/infrastructure-*.sops.json) ;;
  *)
    printf 'Refusing a state snapshot outside %s.\n' "${snapshot_root}" >&2
    exit 2
    ;;
esac

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
' "${snapshot}" >/dev/null; then
  printf 'Refusing a state snapshot that is not fully SOPS-encrypted.\n' >&2
  exit 1
fi

# Plaintext exists only between the two processes. jq validates the decrypted
# payload as a non-empty OpenTofu state before the encrypted backend accepts it.
"${sops_binary}" --decrypt --input-type json --output-type json "${snapshot}" |
  jq -ce '
    if type == "object"
      and (.version | type == "number")
      and (.serial | type == "number")
      and (.lineage | type == "string" and length > 0)
      and (.resources | type == "array" and length > 0)
    then .
    else error("invalid or empty OpenTofu state snapshot")
    end
  ' |
  TOFU_BINARY="${tofu_binary}" "${repo_root}/Scripts/tofu.sh" \
    -chdir="${tofu_path}" state push -lock-timeout=60s -

printf 'Encrypted local state snapshot restored: %s\n' "${snapshot}"
