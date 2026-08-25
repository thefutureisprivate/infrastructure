#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}

find "${repo_root}/Scripts" "${repo_root}/SOPS" "${repo_root}/Butane" "${repo_root}/Tests" -type f -name '*.sh' -print0 | while IFS= read -r -d '' script; do
  bash -n "${script}"
done
bash -n "${repo_root}/Tests/ansible/mocks/podman" "${repo_root}/Tests/ansible/mocks/systemctl"
printf 'Shell syntax: OK\n'

"${repo_root}/Tests/sops-allowlist.sh"
"${repo_root}/Tests/fcos-rescue-installer.sh"
"${repo_root}/Tests/stalwart-bootstrap.sh"

bash "${repo_root}/Scripts/check-stalwart-hardening-plan.sh"
jq -e -s '
  length == 1
  and .[0]."@type" == "update"
  and .[0].object == "MtaSts"
  and .[0].value == {"mode": "enforce", "maxAge": 604800000, "mxHosts": {}}
' "${repo_root}/Stalwart/mta-sts.ndjson" >/dev/null
grep -Fq -- 'run_cli create Action/ReloadSettings' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- '--env "STALWART_URL=${STALWART_URL}"' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'type=env,target=STALWART_TOKEN' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'container_engine podman secret create "${runtime_token_secret}" -' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'container_engine podman secret rm "${runtime_token_secret}"' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'walk(if type == "object" and .match? == {} then del(.match) else . end);' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
if grep -Fq -- '--env "STALWART_TOKEN=' "${repo_root}/Scripts/stalwart-hardening.sh"; then
  printf 'The Stalwart API token must not be placed in container arguments.\n' >&2
  exit 1
fi
printf 'Stalwart hardening plan: OK\n'

if [[ $(grep -Fc -- 'auto_delete       = false' "${repo_root}/OpenTofu/main.tf") -ne 2 ]]; then
  printf 'Both Hetzner Primary IP resource families must disable automatic deletion.\n' >&2
  exit 1
fi
if [[ $(grep -Fc -- 'delete_protection = true' "${repo_root}/OpenTofu/main.tf") -ne 2 ]]; then
  printf 'Both Hetzner Primary IP resource families must enable deletion protection.\n' >&2
  exit 1
fi
if [[ $(grep -Fc -- 'prevent_destroy = true' "${repo_root}/OpenTofu/main.tf") -ne 2 ]]; then
  printf 'Both Hetzner Primary IP resource families must prevent destruction.\n' >&2
  exit 1
fi
grep -Fq -- 'try(var.primary_ip_import_ids[each.key].ipv4, null) == null' \
  "${repo_root}/OpenTofu/main.tf"
grep -Fq -- 'try(var.primary_ip_import_ids[each.key].ipv6, null) == null' \
  "${repo_root}/OpenTofu/main.tf"
printf 'Hetzner Primary IP protection: OK\n'

"${repo_root}/Scripts/verify-container-provenance.sh" --offline

SSH_PUBLIC_KEY_FILE="${repo_root}/Tests/fixtures/ssh-authorized-key.pub" \
  "${repo_root}/Scripts/render-ignition.sh" "${repo_root}/build/fcos.ign"
python3 "${repo_root}/Tests/verify-resolved-ignition.py" "${repo_root}/build/fcos.ign"
printf 'Butane: OK\n'

if command -v "${tofu_bin}" >/dev/null 2>&1; then
  "${tofu_bin}" -chdir="${repo_root}/OpenTofu" fmt -check -recursive
  if [[ -d "${repo_root}/OpenTofu/.terraform" ]]; then
    "${tofu_bin}" -chdir="${repo_root}/OpenTofu" validate
  else
    printf 'OpenTofu validate: skipped (run make tofu-init first)\n'
  fi
else
  printf 'OpenTofu checks: skipped (%s not installed)\n' "${tofu_bin}"
fi

if command -v yamllint >/dev/null 2>&1; then
  yamllint -c "${repo_root}/.yamllint.yml" \
    "${repo_root}/.github" \
    "${repo_root}/Ansible" \
    "${repo_root}/Butane" \
    "${repo_root}/SOPS" \
    "${repo_root}/Tests/ansible/idempotence.yml"
else
  printf 'yamllint: skipped (not installed)\n'
fi

if command -v ansible-playbook >/dev/null 2>&1; then
  ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" \
    ansible-playbook --syntax-check \
    -i "${repo_root}/Ansible/inventory/hosts.example.yml" \
    "${repo_root}/Ansible/playbooks/quadlets.yml"
  ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" \
    "${repo_root}/Tests/ansible-idempotence.sh"
else
  printf 'Ansible syntax check: skipped (ansible-playbook not installed)\n'
fi

if command -v ansible-lint >/dev/null 2>&1; then
  (cd "${repo_root}" && ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" ansible-lint Ansible Tests/ansible/idempotence.yml)
else
  printf 'ansible-lint: skipped (not installed)\n'
fi
