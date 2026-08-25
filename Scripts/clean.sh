#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

# Only generated files under explicit repository paths are removed.
rm -f -- "${repo_root}/build/fcos.ign"
rm -f -- "${repo_root}/Ansible/inventory/hosts.yml"
rm -f -- "${repo_root}/OpenTofu/main.tfplan"
printf 'Removed generated Ignition, inventory, and plan artifacts.\n'
