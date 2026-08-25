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

export PATH="${mock_dir}:${PATH}"
export FCOS_TEST_API_STATE="${test_dir}/api-state"
export FCOS_TEST_API_LOG="${test_dir}/api-log"
export HCLOUD_TOKEN=test-token
export IGNITION_FILE="${test_dir}/fcos.ign"
export TMPDIR="${test_dir}"
export TOFU=tofu
export CONTAINER_RUNTIME=podman

"${repo_root}/Scripts/install-fcos.sh" >/dev/null
if [[ $(<"${FCOS_TEST_API_STATE}") != installed ]]; then
  printf 'Direct installer did not record a verified installation.\n' >&2
  exit 1
fi
first_action_count=$(grep -cE '/actions/(enable_rescue|reset)' "${FCOS_TEST_API_LOG}")
if [[ ${first_action_count} != 3 ]]; then
  printf 'Direct installer did not perform exactly one rescue activation and two required boots.\n' >&2
  exit 1
fi

"${repo_root}/Scripts/install-fcos.sh" >/dev/null
second_action_count=$(grep -cE '/actions/(enable_rescue|reset)' "${FCOS_TEST_API_LOG}")
if [[ ${second_action_count} != "${first_action_count}" ]]; then
  printf 'Direct installer repeated a destructive installation without authorization.\n' >&2
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
