#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
ansible_playbook=${ANSIBLE_PLAYBOOK:-ansible-playbook}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/infrastructure-ansible-idempotence.XXXXXX")

cleanup() {
  if ((EUID == 0)); then
    rm -rf -- "${test_root}"
  else
    sudo -n rm -rf -- "${test_root}"
  fi
}
trap cleanup EXIT HUP INT TERM

if ((EUID == 0)); then
  become=false
elif command -v sudo >/dev/null 2>&1 && sudo -n true; then
  become=true
elif [[ ${ANSIBLE_IDEMPOTENCE_USERNS:-0} != 1 ]] \
  && command -v unshare >/dev/null 2>&1 \
  && unshare --user --map-root-user true 2>/dev/null; then
  exec unshare --user --map-root-user \
    env ANSIBLE_IDEMPOTENCE_USERNS=1 "$0"
else
  printf '%s\n' \
    "The Ansible idempotence test requires root, passwordless sudo, or an unprivileged user namespace." >&2
  exit 1
fi

mkdir -p -- "${test_root}/quadlets" "${test_root}/systemd" "${test_root}/secret-state" \
  "${test_root}/state/bin" "${test_root}/state/services" "${test_root}/state/enabled" "${test_root}/state/secrets"
install -m 0755 -- "${repo_root}/Tests/ansible/mocks/podman" "${test_root}/state/bin/podman"
install -m 0755 -- "${repo_root}/Tests/ansible/mocks/systemctl" "${test_root}/state/bin/systemctl"
printf '%s\n' "obsolete" >"${test_root}/quadlets/retired.container"
printf '%s\n' "obsolete" >"${test_root}/quadlets/retired.conf"
printf '%s\n' "obsolete" >"${test_root}/state/secrets/retired-secret"
printf '%s\n' "obsolete" >"${test_root}/secret-state/retired-secret.sha256"
printf '%s\n' "obsolete" >"${test_root}/state/secrets/retired-secret-without-dependents"
printf '%s\n' "obsolete" >"${test_root}/secret-state/retired-secret-without-dependents.sha256"
printf '%s\n' "obsolete" >"${test_root}/systemd/retired-backup.timer"
touch -- "${test_root}/state/services/retired.service" "${test_root}/state/services/retired-backup.timer" \
  "${test_root}/state/enabled/retired-backup.timer" "${test_root}/state/mutations.log"
chmod 0777 "${test_root}/quadlets" "${test_root}/systemd" "${test_root}/secret-state"

run_playbook() {
  ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" \
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_IDEMPOTENCE_BECOME="${become}" \
  ANSIBLE_IDEMPOTENCE_ROOT="${test_root}" \
    "${ansible_playbook}" \
      -i "localhost," \
      "${repo_root}/Tests/ansible/idempotence.yml"
}

compare_privileged_file_with_stdin() {
  local path=$1
  if [[ ${become} == true ]]; then
    sudo -n cmp -s - "${path}"
  else
    cmp -s - "${path}"
  fi
}

if ! first_run=$(run_playbook); then
  printf '%s\n' "${first_run}"
  exit 1
fi
printf '%s\n' "${first_run}"
if ! grep -Eq 'changed=[1-9][0-9]*' <<<"${first_run}"; then
  printf '%s\n' "The first Ansible run did not report the expected reconciliation changes." >&2
  exit 1
fi

mutations_after_first=$(wc -l <"${test_root}/state/mutations.log")
expected_secret=$'correct-horse-battery-staple-idempotence\nshell metacharacters stay data: $() ; '\'' " \\'
if ! printf '%s' "${expected_secret}" | \
  compare_privileged_file_with_stdin "${test_root}/state/secrets/test-secret"; then
  printf '%s\n' "Podman did not receive the exact multiline secret over standard input." >&2
  exit 1
fi
if ! second_run=$(run_playbook); then
  printf '%s\n' "${second_run}"
  exit 1
fi
printf '%s\n' "${second_run}"
if ! grep -Eq 'changed=0([[:space:]]|$)' <<<"${second_run}"; then
  printf '%s\n' "The second Ansible run was not idempotent." >&2
  exit 1
fi
if ! grep -Eq 'failed=0([[:space:]]|$)' <<<"${second_run}"; then
  printf '%s\n' "The second Ansible run failed." >&2
  exit 1
fi

mutations_after_second=$(wc -l <"${test_root}/state/mutations.log")
if [[ ${mutations_after_second} -ne ${mutations_after_first} ]]; then
  printf '%s\n' "The second Ansible run performed a hidden service or secret mutation." >&2
  exit 1
fi

printf '%s\n' "Ansible idempotence: OK"
