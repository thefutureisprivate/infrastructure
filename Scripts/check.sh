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

jq -e -s '
  length == 4 and
  (map(."@type") == ["reconcile", "update", "update", "reconcile"]) and
  (map(.object) == ["NetworkListener", "Http", "MtaStageAuth", "Application"]) and
  (.[0].value | keys | sort == ["https", "imaps", "smtp", "submissions"]) and
  (.[0].value.smtp.tlsImplicit == false) and
  (.[0].value.submissions.tlsImplicit == true) and
  (.[0].value.imaps.tlsImplicit == true) and
  (.[0].value.https.tlsImplicit == true) and
  (.[1].value.enableHsts == true) and
  (.[1].value.usePermissiveCors == false) and
  (.[1].value.useXForwarded == false) and
  (.[1].value.responseHeaders["Content-Security-Policy"] | contains("default-src"))
  and (.[3].value.webui.resourceUrl == "file:///opt/stalwart-webui/webui.zip")
  and (.[3].value.webui.urlPrefix | keys | sort == ["/account", "/admin"])
' "${repo_root}/Stalwart/hardening.ndjson" >/dev/null
printf 'Stalwart hardening plan: OK\n'

"${repo_root}/Scripts/verify-container-provenance.sh" --offline

SSH_PUBLIC_KEY_FILE="${repo_root}/Tests/fixtures/ssh-authorized-key.pub" \
  "${repo_root}/Scripts/render-ignition.sh" "${repo_root}/build/fcos.ign"
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
