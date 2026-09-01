#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

# Only generated files under explicit repository paths are removed. The entire
# build tree is reproducible and may contain large source-review checkouts.
rm -rf -- "${repo_root}/build"
rm -f -- "${repo_root}/Ansible/inventory/hosts.yml"
rm -f -- "${repo_root}/Ansible/inventory/known_hosts.old"
rm -f -- "${repo_root}/OpenTofu/main.tfplan"
rm -f -- "${repo_root}/OpenTofu/recovery-refresh.tfplan"
rm -f -- "${repo_root}/OpenTofu/stalwart-bootstrap.tfplan"
rm -f -- \
  "${repo_root}/silverblue-followup.txt" \
  "${repo_root}/silverblue-inventory.txt" \
  "${repo_root}/silverblue-rpms.tsv"
find "${repo_root}/Scripts" "${repo_root}/Ansible/plugins" \
  -type d -name __pycache__ -prune -exec rm -rf -- {} +
printf 'Removed generated build, inventory, plan, and local audit artifacts.\n'
