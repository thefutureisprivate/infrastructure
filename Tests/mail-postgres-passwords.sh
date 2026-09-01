#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
inventory="${repo_root}/Ansible/inventory/hosts.example.yml"
playbook="${repo_root}/Ansible/playbooks/quadlets.yml"

if ! command -v ansible-playbook >/dev/null 2>&1; then
  printf 'PostgreSQL password isolation guard: skipped (ansible-playbook unavailable)\n'
  exit 0
fi

run_validation() {
  MAIL_POSTGRES_ADMIN_PASSWORD=$1 \
  MAIL_POSTGRES_PASSWORD=$2 \
  MAIL_POSTGRES_DUMP_PASSWORD=$3 \
  ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" \
    ansible-playbook \
      --inventory "${inventory}" \
      --limit mail-01 \
      --tags mail-postgres-credentials \
      "${playbook}" >/dev/null 2>&1
}

admin_password='admin-password-0123456789-abcdef'
app_password='application-password-0123456789-abcdef'
dump_password='dump-password-0123456789-abcdefgh'

run_validation "${admin_password}" "${app_password}" "${dump_password}"

for duplicate_pair in admin-app admin-dump app-dump; do
  case "${duplicate_pair}" in
    admin-app)
      candidate_admin=${admin_password}
      candidate_app=${admin_password}
      candidate_dump=${dump_password}
      ;;
    admin-dump)
      candidate_admin=${admin_password}
      candidate_app=${app_password}
      candidate_dump=${admin_password}
      ;;
    app-dump)
      candidate_admin=${admin_password}
      candidate_app=${app_password}
      candidate_dump=${app_password}
      ;;
  esac

  if run_validation "${candidate_admin}" "${candidate_app}" "${candidate_dump}"; then
    printf 'Duplicate PostgreSQL credentials were accepted: %s\n' "${duplicate_pair}" >&2
    exit 1
  fi
done

printf 'PostgreSQL password isolation guard: OK\n'
