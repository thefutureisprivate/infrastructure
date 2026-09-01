#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
mock_dir="${repo_root}/Tests/mocks/fcos"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/fcos-rescue-test.XXXXXX")
trap 'rm -rf -- "${test_dir}"' EXIT HUP INT TERM

for mock in curl podman scp ssh tofu; do
  bash -n "${mock_dir}/${mock}"
done

printf '%s\n' '{"ignition":{"version":"3.5.0"}}' >"${test_dir}/fcos.ign"
printf 'pending\n' >"${test_dir}/api-state"
: >"${test_dir}/api-log"
: >"${test_dir}/ssh-log"

export PATH="${mock_dir}:${PATH}"
export FCOS_TEST_API_STATE="${test_dir}/api-state"
export FCOS_TEST_API_LOG="${test_dir}/api-log"
export FCOS_TEST_SSH_LOG="${test_dir}/ssh-log"
export FCOS_KNOWN_HOSTS_FILE="${test_dir}/known-hosts"
export FCOS_SSH_ATTEMPTS=1
export FCOS_SSH_RETRY_DELAY=0
export HCLOUD_TOKEN=test-token
export IGNITION_FILE="${test_dir}/fcos.ign"
export TMPDIR="${test_dir}"
export TOFU=tofu
export CONTAINER_RUNTIME=podman

if ! awk '
  /wait_for_ssh\(\)/ { in_function = 1 }
  in_function && /attempt <= ssh_attempts/ { found = 1 }
  in_function && /^}/ { exit(found ? 0 : 1) }
' "${repo_root}/Scripts/install-fcos.sh"; then
  printf 'FCOS_SSH_ATTEMPTS is not wired to the SSH readiness loop.\n' >&2
  exit 1
fi

export FCOS_TEST_FAIL_STRICT=1
if "${repo_root}/Scripts/install-fcos.sh" >/dev/null 2>&1; then
  printf 'Direct installer accepted an unverified permanent SSH host key.\n' >&2
  exit 1
fi
if [[ ! -f ${FCOS_KNOWN_HOSTS_FILE} || -L ${FCOS_KNOWN_HOSTS_FILE} || \
      $(stat -c '%a' "${FCOS_KNOWN_HOSTS_FILE}") != 600 ]]; then
  printf 'Direct installer did not create a safe first-install trust file.\n' >&2
  exit 1
fi
if [[ $(<"${FCOS_TEST_API_STATE}") != awaiting-verification ]]; then
  printf 'Direct installer did not preserve the awaiting-verification marker.\n' >&2
  exit 1
fi
first_action_count=$(grep -cE '/actions/(enable_rescue|reset)' "${FCOS_TEST_API_LOG}")
if [[ ${first_action_count} != 3 ]]; then
  printf 'Direct installer did not perform exactly one rescue activation and two required boots.\n' >&2
  exit 1
fi
grep -Fq -- 'StrictHostKeyChecking=accept-new' "${FCOS_TEST_SSH_LOG}"
grep -Fq -- 'StrictHostKeyChecking=yes' "${FCOS_TEST_SSH_LOG}"
grep -Fq -- 'HostKeyAlias=mail.thefutureisprivate.dev' "${FCOS_TEST_SSH_LOG}"

export FCOS_TEST_FAIL_STRICT=0
"${repo_root}/Scripts/install-fcos.sh" >/dev/null
if [[ $(<"${FCOS_TEST_API_STATE}") != installed ]]; then
  printf 'Direct installer did not record a pinned and verified installation.\n' >&2
  exit 1
fi
second_action_count=$(grep -cE '/actions/(enable_rescue|reset)' "${FCOS_TEST_API_LOG}")
if [[ ${second_action_count} != "${first_action_count}" ]]; then
  printf 'Direct installer repeated a destructive installation without authorization.\n' >&2
  exit 1
fi

"${repo_root}/Scripts/install-fcos.sh" >/dev/null
third_action_count=$(grep -cE '/actions/(enable_rescue|reset)' "${FCOS_TEST_API_LOG}")
if [[ ${third_action_count} != "${first_action_count}" ]]; then
  printf 'Direct installer repeated a destructive installation for an installed node.\n' >&2
  exit 1
fi

if "${repo_root}/Scripts/install-fcos-rescue-remote.sh" \
  missing.tar.gz missing.ign stable aarch64 /dev/sda \
  "$(printf x | sha256sum | awk '{print $1}')" \
  "$(printf y | sha256sum | awk '{print $1}')" \
  "$(printf z | sha256sum | awk '{print $1}')" >/dev/null 2>&1; then
  printf 'Remote installer accepted an unsupported architecture.\n' >&2
  exit 1
fi

for required_karg in rd.neednet=1 ip=dhcp; do
  if ! grep -Fq -- "--append-karg ${required_karg}" \
    "${repo_root}/Scripts/install-fcos-rescue-remote.sh"; then
    printf 'Remote installer does not enable first-boot networking with %s.\n' \
      "${required_karg}" >&2
    exit 1
  fi
done
if ! grep -Fq -- 'sudo -n /usr/bin/true' "${repo_root}/Scripts/install-fcos.sh"; then
  printf 'Direct installer does not verify non-interactive operator sudo.\n' >&2
  exit 1
fi
if ! grep -Fq -- '/usr/local/bin/runsc --version' \
  "${repo_root}/Scripts/install-fcos.sh"; then
  printf 'Direct installer does not verify the installed gVisor runtime.\n' >&2
  exit 1
fi

printf 'Direct FCOS rescue installer guards: OK\n'
