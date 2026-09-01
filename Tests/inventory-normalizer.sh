#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/inventory-normalizer.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

input_path="${test_root}/input.yml"
output_path="${test_root}/output.yml"

render_input() {
  local extra_variable=${1:-}
  {
    printf '%s\n' \
      '---' \
      'all:' \
      '  children:' \
      '    fcos:' \
      '      children:' \
      '        mail:' \
      '          hosts:' \
      '            mail-01:' \
      '              ansible_host: "mail.example.com"' \
      '              node_key: "01"' \
      '              mail_hostname: "mail.example.com"' \
      '              mail_backup_enabled: false' \
      '              mail_backup_age_recipient: ""' \
      '              mail_backup_hetzner_bucket: "backup-de"' \
      '              mail_backup_hetzner_endpoint: "nbg1.your-objectstorage.com"' \
      '              mail_backup_hetzner_region: "nbg1"' \
      '              mail_backup_b2_bucket: "backup-nl"' \
      '              mail_backup_b2_endpoint: "s3.eu-central-003.backblazeb2.com"' \
      '              mail_backup_b2_region: "eu-central-003"' \
      '              mail_backup_scaleway_bucket: "backup-fr"' \
      '              mail_backup_scaleway_endpoint: "https://s3.fr-par.scw.cloud"' \
      '              mail_backup_scaleway_region: "fr-par"'
    [[ -z ${extra_variable} ]] || printf '%s\n' "              ${extra_variable}"
    printf '%s\n' \
      '  vars:' \
      '    ansible_user: "operator"'
  } >"${input_path}"
}

render_input
python3 "${repo_root}/Scripts/normalize-inventory.py" "${input_path}" "${output_path}"

python3 - "${output_path}" <<'PY'
import sys
from pathlib import Path

import yaml

inventory = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
host = inventory["all"]["children"]["fcos"]["children"]["mail"]["hosts"]["mail-01"]
expected = {
    "ansible_host": "mail.example.com",
    "node_key": "01",
    "mail_hostname": "mail.example.com",
    "mail_backup_enabled": False,
    "mail_backup_age_recipient": "",
    "mail_backup_hetzner_bucket": "backup-de",
    "mail_backup_hetzner_endpoint": "nbg1.your-objectstorage.com",
    "mail_backup_hetzner_region": "nbg1",
    "mail_backup_b2_bucket": "backup-nl",
    "mail_backup_b2_endpoint": "s3.eu-central-003.backblazeb2.com",
    "mail_backup_b2_region": "eu-central-003",
    "mail_backup_scaleway_bucket": "backup-fr",
    "mail_backup_scaleway_endpoint": "https://s3.fr-par.scw.cloud",
    "mail_backup_scaleway_region": "fr-par",
}
if host != expected:
    raise SystemExit(f"normalized inventory lost or changed host variables: {host!r}")
PY

render_input 'unexpected_variable: "rejected"'
if python3 "${repo_root}/Scripts/normalize-inventory.py" \
  "${input_path}" "${output_path}" >/dev/null 2>&1; then
  printf 'Inventory normalizer accepted an undeclared host variable.\n' >&2
  exit 1
fi

printf 'Generated inventory schema preservation: OK\n'
