#!/usr/bin/env bash
set -euo pipefail

metadata_url=${HETZNER_NETWORK_METADATA_URL:-http://169.254.169.254/hetzner/v1/metadata/network-config}

for command_name in curl nmcli sed tr; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required to configure Hetzner IPv6\n' "${command_name}" >&2
    exit 1
  }
done

metadata=$(curl --noproxy '*' --proto '=http' \
  --fail --silent --show-error --max-time 10 "${metadata_url}")
mac_address=$(sed -nE 's/^[[:space:]]*(-[[:space:]]*)?mac_address:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\2/p' \
  <<<"${metadata}" | head -n 1 | tr '[:upper:]' '[:lower:]')
ipv6_address=$(sed -nE 's/^[[:space:]]*-[[:space:]]*address:[[:space:]]*([^[:space:]]*:[^[:space:]]*\/[0-9]+)[[:space:]]*$/\1/p' \
  <<<"${metadata}" | head -n 1)
ipv6_gateway=$(sed -nE 's/^[[:space:]]*gateway:[[:space:]]*([^[:space:]]*:[^[:space:]]*)[[:space:]]*$/\1/p' \
  <<<"${metadata}" | head -n 1)

if [[ ! ${mac_address} =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
  printf 'Hetzner metadata did not contain one valid interface MAC address\n' >&2
  exit 1
fi
if [[ ! ${ipv6_address} =~ ^[0-9A-Fa-f:]+/([0-9]{1,3})$ ]] || \
  ((10#${BASH_REMATCH[1]} > 128)); then
  printf 'Hetzner metadata did not contain one valid static IPv6 prefix\n' >&2
  exit 1
fi
if [[ ! ${ipv6_gateway} =~ ^[0-9A-Fa-f:]+$ ]]; then
  printf 'Hetzner metadata did not contain one valid IPv6 gateway\n' >&2
  exit 1
fi

interface=''
for address_file in /sys/class/net/*/address; do
  [[ -r ${address_file} ]] || continue
  read -r candidate_mac <"${address_file}"
  if [[ ${candidate_mac,,} == "${mac_address}" ]]; then
    interface=${address_file%/address}
    interface=${interface##*/}
    break
  fi
done
if [[ -z ${interface} ]]; then
  printf 'No local interface matches Hetzner metadata MAC %s\n' "${mac_address}" >&2
  exit 1
fi

connection=$(nmcli -g GENERAL.CONNECTION device show "${interface}")
if [[ -z ${connection} || ${connection} == '--' || ${connection} == *$'\n'* ]]; then
  printf 'No active NetworkManager connection exists for %s\n' "${interface}" >&2
  exit 1
fi

current_method=$(nmcli -g ipv6.method connection show "${connection}")
current_addresses=$(nmcli -g ipv6.addresses connection show "${connection}")
current_gateway=$(nmcli -g ipv6.gateway connection show "${connection}")
if [[ ${current_method} == manual && ${current_addresses} == "${ipv6_address}" && \
  ${current_gateway} == "${ipv6_gateway}" ]]; then
  exit 0
fi

nmcli connection modify "${connection}" \
  ipv6.method manual \
  ipv6.addresses "${ipv6_address}" \
  ipv6.gateway "${ipv6_gateway}" \
  ipv6.ignore-auto-dns yes
nmcli device reapply "${interface}"
printf 'Configured %s with Hetzner IPv6 address %s via %s\n' \
  "${interface}" "${ipv6_address}" "${ipv6_gateway}"
