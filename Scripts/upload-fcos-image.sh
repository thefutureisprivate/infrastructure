#!/usr/bin/env bash
set -euo pipefail

stream=${FCOS_STREAM:-stable}
fcos_architecture=${FCOS_ARCHITECTURE:-x86_64}
location=${FCOS_LOCATION:-fsn1}
runtime=${CONTAINER_RUNTIME:-auto}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
coreos_installer_image=$("${repo_root}/Scripts/tool-image.sh" coreos-installer)
hcloud_uploader_image=$("${repo_root}/Scripts/tool-image.sh" hcloud-upload-image)

if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  printf 'HCLOUD_TOKEN is required.\n' >&2
  exit 2
fi

case "${fcos_architecture}" in
  x86_64) hcloud_architecture=x86 ;;
  aarch64) hcloud_architecture=arm ;;
  *)
    printf 'FCOS_ARCHITECTURE must be x86_64 or aarch64.\n' >&2
    exit 2
    ;;
esac

download_dir=$(mktemp -d "${TMPDIR:-/tmp}/fcos-image.XXXXXX")
trap 'rm -rf -- "${download_dir}"' EXIT HUP INT TERM

download_container() {
  local engine=$1
  local mount_suffix=rw
  if [[ "${engine}" == "podman" ]]; then
    mount_suffix=rw,Z
  fi
  "${engine}" run --rm --interactive --read-only \
    --user "$(id -u):$(id -g)" \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
    --volume "${download_dir}:/data:${mount_suffix}" \
    "${coreos_installer_image}" download \
    --stream "${stream}" \
    --platform hetzner \
    --format raw.xz \
    --architecture "${fcos_architecture}" \
    --directory /data
}

case "${runtime}" in
  auto)
    if command -v podman >/dev/null 2>&1; then
      runtime=podman
      download_container podman
    elif command -v docker >/dev/null 2>&1; then
      runtime=docker
      download_container docker
    else
      printf 'Install Podman or Docker to use the pinned FCOS deployment tools.\n' >&2
      exit 1
    fi
    ;;
  podman|docker)
    command -v "${runtime}" >/dev/null 2>&1 || { printf '%s is not installed.\n' "${runtime}" >&2; exit 1; }
    download_container "${runtime}"
    ;;
  *)
    printf 'CONTAINER_RUNTIME must be auto, podman, or docker.\n' >&2
    exit 2
    ;;
esac

image_path=$(find "${download_dir}" -type f -name '*-hetzner.*.raw.xz' -print -quit)
if [[ -z "${image_path}" ]]; then
  printf 'coreos-installer did not produce a Hetzner raw.xz image.\n' >&2
  exit 1
fi

printf 'Uploading %s. This creates a temporary billable server and a snapshot.\n' "${image_path}"
mount_suffix=ro
if [[ ${runtime} == podman ]]; then
  mount_suffix=ro,Z
fi
"${runtime}" run --rm --interactive --read-only \
  --user "$(id -u):$(id -g)" \
  --cap-drop=all \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
  --env HOME=/tmp \
  --env HCLOUD_TOKEN \
  --volume "${download_dir}:/data:${mount_suffix}" \
  "${hcloud_uploader_image}" upload \
  --image-path "/data/$(basename -- "${image_path}")" \
  --architecture "${hcloud_architecture}" \
  --compression xz \
  --location "${location}" \
  --description "Fedora CoreOS ${stream} (${fcos_architecture})" \
  --labels "os=fcos,stream=${stream},managed-by=fcos-infrastructure"
