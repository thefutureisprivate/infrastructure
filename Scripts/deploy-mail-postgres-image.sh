#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
inventory_file=${MAIL_INVENTORY_FILE:-${repo_root}/Ansible/inventory/hosts.yml}
known_hosts_file=${MAIL_KNOWN_HOSTS_FILE:-${repo_root}/Ansible/inventory/known_hosts}
compose_file=${MAIL_IMAGE_LOCK_FILE:-${repo_root}/Ansible/compose.yaml}
containerfile=${MAIL_POSTGRES_CONTAINERFILE:-${repo_root}/Ansible/quadlets/mail-postgres.Containerfile}
image_reference_helper=${MAIL_POSTGRES_IMAGE_REFERENCE_HELPER:-${repo_root}/Scripts/mail-postgres-backup-image-ref.py}
container_runtime=${CONTAINER_RUNTIME:-podman}

for input in "${inventory_file}" "${known_hosts_file}" "${compose_file}" "${containerfile}" "${image_reference_helper}"; do
  [[ -r ${input} ]] || { printf 'Required image-deployment input is missing: %s\n' "${input}" >&2; exit 2; }
done
mapfile -t enabled_hosts < <(python3 - "${inventory_file}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    inventory = yaml.safe_load(handle)
all_group = inventory["all"]
default_user = all_group["vars"]["ansible_user"]
hosts = all_group["children"]["fcos"]["children"]["mail"]["hosts"]
for name, host in sorted(hosts.items()):
    if host.get("mail_backup_enabled") is True:
        print(f'{name}\t{host["ansible_host"]}\t{host.get("ansible_user", default_user)}')
PY
)
if ((${#enabled_hosts[@]} == 0)); then
  printf 'Mail backups are disabled; no PostgreSQL backup image is required.\n'
  exit 0
fi
if [[ ${container_runtime##*/} != podman ]]; then
  printf 'The controller image deployment requires local Podman; unsupported runtime: %s\n' \
    "${container_runtime}" >&2
  exit 2
fi
if [[ -n ${CONTAINER_HOST:-} || -n ${DOCKER_HOST:-} ]]; then
  printf 'Refusing to build through a remote container-runtime endpoint.\n' >&2
  exit 1
fi
command -v "${container_runtime}" >/dev/null || {
  printf 'Controller container runtime is unavailable: %s\n' "${container_runtime}" >&2
  exit 1
}
command -v jq >/dev/null || {
  printf 'jq is required to derive the immutable PostgreSQL backup image reference.\n' >&2
  exit 1
}
container_command=("${container_runtime}" --remote=false)

image_metadata=$(MAIL_IMAGE_LOCK_FILE="${compose_file}" \
  MAIL_POSTGRES_CONTAINERFILE="${containerfile}" \
  "${image_reference_helper}" --json)
base_image=$(jq -er '.base_image' <<<"${image_metadata}")
source_hash=$(jq -er '.source_hash | select(test("^[0-9a-f]{64}$"))' \
  <<<"${image_metadata}")
image_tag=$(jq -er --arg hash "${source_hash}" \
  '.image | select(. == ("localhost/mail-postgres-backup:" + $hash))' \
  <<<"${image_metadata}")
unset image_metadata
current_hash=$(
  "${container_command[@]}" image inspect "${image_tag}" \
    --format '{{ index .Config.Labels "org.opencontainers.image.source-hash" }}' \
    2>/dev/null || true
)
if [[ ${current_hash} != "${source_hash}" ]]; then
  "${container_command[@]}" pull "${base_image}"
  "${container_command[@]}" build --pull=never \
    --build-arg "MAIL_POSTGRES_BASE=${base_image}" \
    --label "org.opencontainers.image.source-hash=${source_hash}" \
    --tag "${image_tag}" --file "${containerfile}" "$(dirname -- "${containerfile}")"
fi

install -d -m 0700 "${repo_root}/build"
archive=$(mktemp "${repo_root}/build/mail-postgres.XXXXXX.oci")
trap 'rm -f -- "${archive}"' EXIT HUP INT TERM
"${container_command[@]}" save --format oci-archive --output "${archive}" "${image_tag}"
archive_sha256=$(sha256sum "${archive}" | awk '{print $1}')

ssh_options=(
  -o BatchMode=yes
  -o ClearAllForwardings=yes
  -o ConnectTimeout=10
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts_file}"
)
for host_row in "${enabled_hosts[@]}"; do
  IFS=$'\t' read -r inventory_name ssh_host ssh_user <<<"${host_row}"
  if [[ ! ${ssh_host} =~ ^[A-Za-z0-9:.%-]+$ || ! ${ssh_user} =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf 'Inventory returned an unsafe SSH endpoint for %s.\n' "${inventory_name}" >&2
    exit 2
  fi
  destination="${ssh_user}@${ssh_host}"
  remote_hash=$(ssh "${ssh_options[@]}" "${destination}" \
    sudo -n podman image inspect "${image_tag}" \
      --format '{{ index .Config.Labels "org.opencontainers.image.source-hash" }}' \
      2>/dev/null || true)
  if [[ ${remote_hash} == "${source_hash}" ]]; then
    printf 'PostgreSQL backup image is current on %s.\n' "${inventory_name}"
    continue
  fi

  remote_archive=$(ssh "${ssh_options[@]}" "${destination}" \
    mktemp /var/tmp/mail-postgres.XXXXXX.oci)
  [[ ${remote_archive} =~ ^/var/tmp/mail-postgres\.[A-Za-z0-9]+\.oci$ ]] || {
    printf 'Remote host returned an unsafe temporary path.\n' >&2
    exit 1
  }
  scp "${ssh_options[@]}" -- "${archive}" "${destination}:${remote_archive}"
  if ! ssh "${ssh_options[@]}" "${destination}" bash -s -- \
      "${remote_archive}" "${archive_sha256}" "${image_tag}" "${source_hash}" <<'REMOTE'
set -euo pipefail
archive=$1
expected_archive_sha256=$2
image_tag=$3
expected_source_hash=$4
trap 'rm -f -- "$archive"' EXIT HUP INT TERM
printf '%s  %s\n' "$expected_archive_sha256" "$archive" | sha256sum --check --status
sudo -n podman load --input "$archive" >/dev/null
actual_source_hash=$(sudo -n podman image inspect "$image_tag" \
  --format '{{ index .Config.Labels "org.opencontainers.image.source-hash" }}')
[[ $actual_source_hash == "$expected_source_hash" ]]
REMOTE
  then
    ssh "${ssh_options[@]}" "${destination}" rm -f -- "${remote_archive}" || true
    exit 1
  fi
  printf 'Installed checksum-verified PostgreSQL backup image on %s.\n' "${inventory_name}"
done
