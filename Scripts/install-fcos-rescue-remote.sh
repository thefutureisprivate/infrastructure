#!/usr/bin/env bash
set -euo pipefail

if (($# != 8)); then
  printf 'Usage: %s <bundle> <ignition> <stream> <architecture> <device> <bundle-sha256> <ignition-sha256> <installer-sha256>\n' "$0" >&2
  exit 2
fi

bundle_archive=$1
ignition_file=$2
stream=$3
architecture=$4
install_device=$5
expected_bundle_sha256=$6
expected_ignition_sha256=$7
expected_installer_sha256=$8
bundle_root=/run/fcos-installer

if ((EUID != 0)); then
  printf 'The rescue installer must run as root.\n' >&2
  exit 1
fi
if [[ ! ${stream} =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'Invalid FCOS stream: %s\n' "${stream}" >&2
  exit 2
fi
if [[ ${architecture} != x86_64 ]]; then
  printf 'Direct rescue installation currently supports x86_64 only.\n' >&2
  exit 2
fi
if [[ ! ${install_device} =~ ^/dev/(sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]+n[0-9]+)$ ]]; then
  printf 'Refusing unexpected install device: %s\n' "${install_device}" >&2
  exit 2
fi
if [[ ! -b ${install_device} ]]; then
  printf 'Install device is not a block device: %s\n' "${install_device}" >&2
  exit 1
fi
if lsblk -nrpo MOUNTPOINT "${install_device}" | grep -qE '^/'; then
  printf 'A filesystem on %s is mounted; refusing to overwrite it.\n' "${install_device}" >&2
  exit 1
fi

printf '%s  %s\n' "${expected_bundle_sha256}" "${bundle_archive}" | sha256sum --check --status
printf '%s  %s\n' "${expected_ignition_sha256}" "${ignition_file}" | sha256sum --check --status

rm -rf -- "${bundle_root}"
install -d -m 0700 -- "${bundle_root}"
tar -xzf "${bundle_archive}" -C "${bundle_root}" --no-same-owner --no-same-permissions

installer="${bundle_root}/usr/bin/coreos-installer"
loader_relative=$(<"${bundle_root}/loader-path")
loader="${bundle_root}/${loader_relative#/}"
library_path=$(<"${bundle_root}/library-path")

if [[ ! ${loader_relative} =~ ^/(lib|lib64|usr/lib|usr/lib64)/[A-Za-z0-9._+-]+$ ]]; then
  printf 'Invalid bundled loader path.\n' >&2
  exit 1
fi
if [[ ! -x ${installer} || ! -x ${loader} ]]; then
  printf 'The transferred CoreOS Installer runtime is incomplete.\n' >&2
  exit 1
fi
if [[ $(sha256sum "${installer}" | awk '{print $1}') != "${expected_installer_sha256}" ]]; then
  printf 'The transferred CoreOS Installer binary failed its digest check.\n' >&2
  exit 1
fi

IFS=: read -r -a library_directories <<<"${library_path}"
runtime_library_path=''
for directory in "${library_directories[@]}"; do
  if [[ ! ${directory} =~ ^/(lib|lib64|usr/lib|usr/lib64)(/[A-Za-z0-9._+-]+)*$ ]]; then
    printf 'Invalid bundled library path: %s\n' "${directory}" >&2
    exit 1
  fi
  if [[ -n ${runtime_library_path} ]]; then
    runtime_library_path+=:
  fi
  runtime_library_path+="${bundle_root}${directory}"
done

printf 'Installing Fedora CoreOS %s for %s on %s.\n' \
  "${stream}" "${architecture}" "${install_device}"
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
  "${loader}" --library-path "${runtime_library_path}" "${installer}" install \
  --stream "${stream}" \
  --architecture "${architecture}" \
  --platform hetzner \
  --ignition-file "${ignition_file}" \
  --console tty0 \
  --console ttyS0,115200n8 \
  "${install_device}"
sync
printf 'Fedora CoreOS installation completed; the controller can now reboot the server.\n'
