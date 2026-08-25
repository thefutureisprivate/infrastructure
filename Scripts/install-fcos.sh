#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
tofu_bin=${TOFU:-tofu}
tofu_dir=${TF_DIR:-"${repo_root}/OpenTofu"}
ignition_file=${IGNITION_FILE:-"${repo_root}/build/fcos.ign"}
stream=${FCOS_STREAM:-stable}
architecture=${FCOS_ARCHITECTURE:-x86_64}
install_device=${FCOS_INSTALL_DEVICE:-/dev/sda}
node_key=${FCOS_NODE_KEY:-}
runtime=${CONTAINER_RUNTIME:-auto}
ssh_private_key=${SSH_PRIVATE_KEY_FILE:-}
reinstall=${FCOS_REINSTALL:-0}
coreos_installer_image=$("${repo_root}/Scripts/tool-image.sh" coreos-installer)
remote_installer="${repo_root}/Scripts/install-fcos-rescue-remote.sh"
api_base=https://api.hetzner.cloud/v1

if [[ -z ${HCLOUD_TOKEN:-} ]]; then
  printf 'HCLOUD_TOKEN is required.\n' >&2
  exit 2
fi
if [[ ! ${HCLOUD_TOKEN} =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'HCLOUD_TOKEN contains unexpected characters.\n' >&2
  exit 2
fi
if [[ ! -r ${ignition_file} ]]; then
  printf 'Ignition file is not readable: %s\n' "${ignition_file}" >&2
  exit 2
fi
if ! jq -e '.ignition.version | type == "string" and length > 0' "${ignition_file}" >/dev/null; then
  printf 'Ignition file is not valid Ignition JSON: %s\n' "${ignition_file}" >&2
  exit 2
fi
if [[ ${architecture} != x86_64 ]]; then
  printf 'Direct rescue installation currently supports x86_64 only.\n' >&2
  exit 2
fi
if [[ ! ${stream} =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'Invalid FCOS stream: %s\n' "${stream}" >&2
  exit 2
fi
if [[ ! ${install_device} =~ ^/dev/(sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]+n[0-9]+)$ ]]; then
  printf 'Invalid FCOS_INSTALL_DEVICE: %s\n' "${install_device}" >&2
  exit 2
fi
if [[ -n ${node_key} && ! ${node_key} =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
  printf 'Invalid FCOS_NODE_KEY: %s\n' "${node_key}" >&2
  exit 2
fi
if [[ ${reinstall} != 0 && ${reinstall} != 1 ]]; then
  printf 'FCOS_REINSTALL must be 0 or 1.\n' >&2
  exit 2
fi
if [[ -n ${ssh_private_key} && ! -r ${ssh_private_key} ]]; then
  printf 'SSH private key is not readable: %s\n' "${ssh_private_key}" >&2
  exit 2
fi

for command_name in curl jq scp ssh sha256sum tar; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required.\n' "${command_name}" >&2
    exit 1
  }
done
command -v "${tofu_bin}" >/dev/null 2>&1 || {
  printf '%s is required.\n' "${tofu_bin}" >&2
  exit 1
}

work_parent=${TMPDIR:-"${repo_root}/build"}
install -d -m 0700 -- "${work_parent}"
work_dir=$(mktemp -d "${work_parent%/}/fcos-rescue.XXXXXX")
api_config="${work_dir}/curl.conf"
api_response="${work_dir}/api-response.json"
bundle_root="${work_dir}/bundle"
bundle_archive="${work_dir}/coreos-installer-runtime.tar.gz"

cleanup() {
  chmod -R u+w -- "${work_dir}" 2>/dev/null || true
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT HUP INT TERM

chmod 0700 "${work_dir}"
printf 'silent\nshow-error\nfail-with-body\nheader = "Authorization: Bearer %s"\n' \
  "${HCLOUD_TOKEN}" >"${api_config}"
chmod 0600 "${api_config}"

api_request() {
  local method=$1 path=$2 payload=${3:-}
  local -a args=(
    --config "${api_config}"
    --request "${method}"
    --output "${api_response}"
    --url "${api_base}${path}"
  )

  if [[ -n ${payload} ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "${payload}")
  fi
  if ! curl "${args[@]}"; then
    printf 'Hetzner API request failed: %s %s\n' "${method}" "${path}" >&2
    return 1
  fi
}

wait_for_action() {
  local action_id=$1
  local status error_message attempt

  if [[ ! ${action_id} =~ ^[0-9]+$ ]]; then
    printf 'Hetzner returned an invalid action ID.\n' >&2
    return 1
  fi
  for ((attempt = 1; attempt <= 90; attempt++)); do
    api_request GET "/actions/${action_id}"
    status=$(jq -r '.action.status // empty' "${api_response}")
    case "${status}" in
      success)
        return 0
        ;;
      error)
        error_message=$(jq -r '.action.error.message // "unknown Hetzner action error"' "${api_response}")
        printf 'Hetzner action %s failed: %s\n' "${action_id}" "${error_message}" >&2
        return 1
        ;;
      running)
        sleep 2
        ;;
      *)
        printf 'Hetzner action %s returned invalid status: %s\n' "${action_id}" "${status}" >&2
        return 1
        ;;
    esac
  done
  printf 'Timed out waiting for Hetzner action %s.\n' "${action_id}" >&2
  return 1
}

server_json() {
  local server_id=$1
  api_request GET "/servers/${server_id}"
  jq -c '.server' "${api_response}"
}

set_install_state() {
  local server_id=$1 state=$2 current labels payload
  current=$(server_json "${server_id}")
  labels=$(jq -c --arg state "${state}" '.labels + {"fcos-installation": $state}' <<<"${current}")
  payload=$(jq -cn --argjson labels "${labels}" '{labels: $labels}')
  api_request PUT "/servers/${server_id}" "${payload}"
}

power_cycle() {
  local server_id=$1 action_id
  api_request POST "/servers/${server_id}/actions/powercycle" '{}'
  action_id=$(jq -r '.action.id // empty' "${api_response}")
  wait_for_action "${action_id}"
}

enable_rescue() {
  local server_id=$1 ssh_key_id=$2 payload action_id
  payload=$(jq -cn --argjson ssh_key_id "${ssh_key_id}" \
    '{type: "linux64", ssh_keys: [$ssh_key_id]}')
  api_request POST "/servers/${server_id}/actions/enable_rescue" "${payload}"
  action_id=$(jq -r '.action.id // empty' "${api_response}")
  wait_for_action "${action_id}"
  power_cycle "${server_id}"
}

resolve_runtime() {
  case "${runtime}" in
    auto)
      if command -v podman >/dev/null 2>&1; then
        runtime=podman
      elif command -v docker >/dev/null 2>&1; then
        runtime=docker
      else
        printf 'Install Podman or Docker to extract the pinned CoreOS Installer runtime.\n' >&2
        exit 1
      fi
      ;;
    podman|docker)
      command -v "${runtime}" >/dev/null 2>&1 || {
        printf '%s is not installed.\n' "${runtime}" >&2
        exit 1
      }
      ;;
    *)
      printf 'CONTAINER_RUNTIME must be auto, podman, or docker.\n' >&2
      exit 2
      ;;
  esac
}

create_installer_bundle() {
  local mount_suffix=rw
  local -a user_namespace_args=()
  local -a library_directories=()
  local loader_relative library_path runtime_library_path directory

  install -d -m 0700 -- "${bundle_root}"
  if [[ ${runtime} == podman ]]; then
    mount_suffix=rw,Z
    user_namespace_args=(--userns=keep-id)
  fi
  "${runtime}" run --rm --read-only \
    "${user_namespace_args[@]}" \
    --user "$(id -u):$(id -g)" \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777 \
    --volume "${bundle_root}:/out:${mount_suffix}" \
    --entrypoint /usr/bin/bash \
    "${coreos_installer_image}" -ceu '
      installer=/usr/bin/coreos-installer
      mapfile -t dependencies < <(
        ldd "${installer}" | awk '\''/ => \// {print $3} $1 ~ /^\// {print $1}'\'' | sort -u
      )
      loader=$(
        printf '\''%s\n'\'' "${dependencies[@]}" |
          awk '\''/\/(ld-linux|ld-[0-9]).*\.so/ {print; exit}'\''
      )
      if [[ -z ${loader} ]]; then
        printf '\''Unable to locate the CoreOS Installer ELF loader.\n'\'' >&2
        exit 1
      fi
      for source_path in "${installer}" "${dependencies[@]}"; do
        destination=/out${source_path}
        mkdir -p -- "$(dirname -- "${destination}")"
        cp --dereference -- "${source_path}" "${destination}"
      done
      printf '\''%s\n'\'' "${loader}" > /out/loader-path
      printf '\''%s\n'\'' "${dependencies[@]}" |
        xargs -r -n1 dirname | sort -u | paste -sd: > /out/library-path
    '

  loader_relative=$(<"${bundle_root}/loader-path")
  library_path=$(<"${bundle_root}/library-path")
  runtime_library_path=''
  IFS=: read -r -a library_directories <<<"${library_path}"
  for directory in "${library_directories[@]}"; do
    if [[ -n ${runtime_library_path} ]]; then
      runtime_library_path+=:
    fi
    runtime_library_path+="${bundle_root}${directory}"
  done
  "${bundle_root}/${loader_relative#/}" \
    --library-path "${runtime_library_path}" \
    "${bundle_root}/usr/bin/coreos-installer" --version >/dev/null
  tar -czf "${bundle_archive}" -C "${bundle_root}" .
}

ssh_options_for() {
  local known_hosts_file=$1
  SSH_OPTIONS=(
    -F /dev/null
    -o BatchMode=yes
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=${known_hosts_file}"
  )
  if [[ -n ${ssh_private_key} ]]; then
    SSH_OPTIONS+=(-o IdentitiesOnly=yes -i "${ssh_private_key}")
  fi
}

wait_for_ssh() {
  local destination=$1 known_hosts_file=$2 remote_check=$3 attempt
  ssh_options_for "${known_hosts_file}"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if ssh "${SSH_OPTIONS[@]}" "${destination}" "${remote_check}" </dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

install_target() {
  local key=$1 target server_id server_name address api_address expected_address install_state
  local rescue_known_hosts fcos_known_hosts ssh_destination scp_destination remote_dir
  local ignition_sha256 bundle_sha256 installer_sha256 current
  local ssh_key_id=$2

  target=$(jq -ce --arg key "${key}" '.[$key]' <<<"${targets_json}")
  server_id=$(jq -r '.id' <<<"${target}")
  server_name=$(jq -r '.name' <<<"${target}")
  address=$(jq -r '.address' <<<"${target}")
  api_address=$(jq -r '.api_address' <<<"${target}")
  if [[ ! ${server_id} =~ ^[0-9]+$ || -z ${address} || ${address} == null || \
        -z ${api_address} || ${api_address} == null ]]; then
    printf 'Invalid OpenTofu install target for node %s.\n' "${key}" >&2
    return 1
  fi

  current=$(server_json "${server_id}")
  if [[ $(jq -r '.name' <<<"${current}") != "${server_name}" ]]; then
    printf 'Hetzner server %s no longer has the OpenTofu-declared name %s.\n' \
      "${server_id}" "${server_name}" >&2
    return 1
  fi
  expected_address=$(jq -r --arg api_address "${api_address}" \
    'if .public_net.ipv4.ip == $api_address or .public_net.ipv6.ip == $api_address then $api_address else empty end' \
    <<<"${current}")
  if [[ -z ${expected_address} ]]; then
    printf 'Hetzner server %s no longer owns address %s.\n' "${server_id}" "${address}" >&2
    return 1
  fi
  install_state=$(jq -r '.labels["fcos-installation"] // empty' <<<"${current}")
  if [[ ${install_state} == installed && ${reinstall} == 0 ]]; then
    printf 'Node %s (%s) is already marked installed; skipping.\n' "${key}" "${server_name}"
    return 0
  fi
  if [[ ${install_state} != pending && ${install_state} != installing && \
        ! ( ${install_state} == installed && ${reinstall} == 1 ) ]]; then
    printf 'Node %s has unexpected fcos-installation label %q; refusing.\n' \
      "${key}" "${install_state}" >&2
    return 1
  fi

  rescue_known_hosts="${work_dir}/known-hosts-rescue-${server_id}"
  fcos_known_hosts="${work_dir}/known-hosts-fcos-${server_id}"
  ssh_destination="root@${address}"
  if [[ ${address} == *:* ]]; then
    scp_destination="root@[${address}]"
  else
    scp_destination="root@${address}"
  fi
  remote_dir="/run/fcos-bootstrap-${server_id}"
  ignition_sha256=$(sha256sum "${ignition_file}" | awk '{print $1}')
  bundle_sha256=$(sha256sum "${bundle_archive}" | awk '{print $1}')
  installer_sha256=$(sha256sum "${bundle_root}/usr/bin/coreos-installer" | awk '{print $1}')

  printf 'Booting node %s (%s) into Hetzner Rescue.\n' "${key}" "${server_name}"
  set_install_state "${server_id}" installing
  enable_rescue "${server_id}" "${ssh_key_id}"
  if ! wait_for_ssh "${ssh_destination}" "${rescue_known_hosts}" true; then
    printf 'Timed out waiting for node %s to enter Hetzner Rescue.\n' "${key}" >&2
    return 1
  fi

  ssh_options_for "${rescue_known_hosts}"
  ssh "${SSH_OPTIONS[@]}" "${ssh_destination}" \
    "install -d -m 0700 -- ${remote_dir}"
  scp "${SSH_OPTIONS[@]}" \
    "${bundle_archive}" \
    "${ignition_file}" \
    "${remote_installer}" \
    "${scp_destination}:${remote_dir}/"
  ssh "${SSH_OPTIONS[@]}" "${ssh_destination}" \
    "bash ${remote_dir}/$(basename -- "${remote_installer}")" \
    "${remote_dir}/$(basename -- "${bundle_archive}")" \
    "${remote_dir}/$(basename -- "${ignition_file}")" \
    "${stream}" "${architecture}" "${install_device}" \
    "${bundle_sha256}" "${ignition_sha256}" "${installer_sha256}"

  printf 'Rebooting node %s into Fedora CoreOS.\n' "${key}"
  power_cycle "${server_id}"
  if ! wait_for_ssh \
    "thefutureisprivate@${address}" \
    "${fcos_known_hosts}" \
    '. /etc/os-release; test "$ID" = fedora; test "${VARIANT_ID:-}" = coreos; test -e /run/ostree-booted'; then
    printf 'Timed out waiting for verified FCOS boot on node %s.\n' "${key}" >&2
    return 1
  fi
  set_install_state "${server_id}" installed
  printf 'Node %s (%s) is running Fedora CoreOS.\n' "${key}" "${server_name}"
}

resolve_runtime
create_installer_bundle

targets_json=$("${tofu_bin}" -chdir="${tofu_dir}" output -json fcos_install_targets)
ssh_key_id=$("${tofu_bin}" -chdir="${tofu_dir}" output -raw rescue_ssh_key_id)
if [[ ! ${ssh_key_id} =~ ^[0-9]+$ ]]; then
  printf 'OpenTofu returned an invalid rescue SSH key ID.\n' >&2
  exit 1
fi

if [[ -n ${node_key} ]]; then
  if ! jq -e --arg key "${node_key}" 'has($key)' <<<"${targets_json}" >/dev/null; then
    printf 'FCOS_NODE_KEY does not exist in the OpenTofu targets: %s\n' "${node_key}" >&2
    exit 2
  fi
  target_keys=("${node_key}")
else
  mapfile -t target_keys < <(jq -r 'keys[]' <<<"${targets_json}")
fi
if ((${#target_keys[@]} == 0)); then
  printf 'OpenTofu returned no FCOS install targets.\n' >&2
  exit 1
fi

for key in "${target_keys[@]}"; do
  install_target "${key}" "${ssh_key_id}"
done
