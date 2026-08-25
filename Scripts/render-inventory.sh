#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}
tofu_dir=${TF_DIR:-"${repo_root}/OpenTofu"}
output_file=${ANSIBLE_INVENTORY:-"${repo_root}/Ansible/inventory/hosts.yml"}

command -v "${tofu_bin}" >/dev/null 2>&1 || { printf '%s is not installed.\n' "${tofu_bin}" >&2; exit 1; }

mkdir -p -- "$(dirname -- "${output_file}")"
temporary_output=$(mktemp "$(dirname -- "${output_file}")/.hosts.yml.XXXXXX")
trap 'rm -f -- "${temporary_output}"' EXIT HUP INT TERM

"${tofu_bin}" -chdir="${tofu_dir}" output -raw ansible_inventory >"${temporary_output}"
chmod 0600 "${temporary_output}"
mv -f -- "${temporary_output}" "${output_file}"
printf 'Wrote %s.\n' "${output_file}"
