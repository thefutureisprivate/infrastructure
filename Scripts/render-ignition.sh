#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
config_file="${repo_root}/Butane/fcos.bu"
output_file=${1:-"${repo_root}/build/fcos.ign"}
key_file=${SSH_PUBLIC_KEY_FILE:-"${repo_root}/Butane/files/operator.pub"}
runtime=${BUTANE_RUNTIME:-auto}
butane_image=$("${repo_root}/Scripts/tool-image.sh" butane)

if [[ ! -r "${key_file}" ]]; then
  printf 'SSH public key is not readable: %s\n' "${key_file}" >&2
  exit 2
fi

if ! grep -Eq '^ssh-(ed25519|rsa)|^ecdsa-sha2-' "${key_file}"; then
  printf 'The public key does not look like an OpenSSH public key: %s\n' "${key_file}" >&2
  exit 2
fi

mkdir -p -- "$(dirname -- "${output_file}")"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/fcos-butane.XXXXXX")
temporary_output=$(mktemp "$(dirname -- "${output_file}")/.fcos.ign.XXXXXX")
trap 'rm -rf -- "${stage_dir}"; rm -f -- "${temporary_output}"' EXIT HUP INT TERM

install -m 0644 -- "${config_file}" "${stage_dir}/fcos.bu"
install -m 0644 -- "${key_file}" "${stage_dir}/ssh-authorized-key.pub"
install -D -m 0755 -- "${repo_root}/Butane/files/install-gvisor.sh" "${stage_dir}/files/install-gvisor.sh"

run_container() {
  local engine=$1
  local mount_suffix=ro
  if [[ "${engine}" == "podman" ]]; then
    mount_suffix=ro,Z
  fi
  "${engine}" run --rm --interactive \
    --volume "${stage_dir}:/work:${mount_suffix}" \
    "${butane_image}" \
    --strict --pretty --files-dir /work /work/fcos.bu >"${temporary_output}"
}

case "${runtime}" in
  auto)
    if command -v podman >/dev/null 2>&1; then
      run_container podman
    elif command -v docker >/dev/null 2>&1; then
      run_container docker
    else
      printf 'Install Podman or Docker to compile Ignition with the pinned Butane image.\n' >&2
      exit 1
    fi
    ;;
  podman|docker)
    command -v "${runtime}" >/dev/null 2>&1 || { printf '%s is not installed.\n' "${runtime}" >&2; exit 1; }
    run_container "${runtime}"
    ;;
  *)
    printf 'BUTANE_RUNTIME must be auto, podman, or docker.\n' >&2
    exit 2
    ;;
esac

ignition_size=$(wc -c <"${temporary_output}")
chmod 0600 "${temporary_output}"
mv -f -- "${temporary_output}" "${output_file}"
printf 'Wrote %s (%d bytes).\n' "${output_file}" "${ignition_size}"
