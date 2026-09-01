#!/usr/bin/env bash
set -euo pipefail

if (($# < 3 || $# > 4)); then
  printf 'Usage: %s CIPHERTEXT MANIFEST SIGNATURE [PUBLIC_KEYRING]\n' "$0" >&2
  exit 2
fi
ciphertext=$1
manifest=$2
signature=$3
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
keyring=${4:-${repo_root}/SOPS/backup-signing-public-keys}

for input in "${ciphertext}" "${manifest}" "${signature}"; do
  [[ -f ${input} && ! -L ${input} ]] || {
    printf 'Unsafe or missing backup input: %s\n' "${input}" >&2
    exit 1
  }
done
[[ -d ${keyring} && ! -L ${keyring} ]] || {
  printf 'Public-key ring is missing: %s\n' "${keyring}" >&2
  exit 1
}

version=$(jq -er '.version | select(. == 1 or . == 2)' "${manifest}")
expected_digest=$(jq -er '.sha256 | select(test("^[0-9a-f]{64}$"))' "${manifest}")
expected_bytes=$(jq -er '.bytes | select(type == "number" and . > 0 and floor == .)' "${manifest}")
[[ $(sha256sum "${ciphertext}" | awk '{print $1}') == "${expected_digest}" ]]
[[ $(stat --format=%s "${ciphertext}") == "${expected_bytes}" ]]

verify_with_key() {
  local public_key=$1 actual_id
  [[ -f ${public_key} && ! -L ${public_key} ]] || return 1
  actual_id=$(openssl pkey -pubin -in "${public_key}" -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}')
  [[ ${public_key##*/} == "${actual_id}.pem" ]] || return 1
  openssl pkeyutl -verify -rawin -pubin -inkey "${public_key}" \
    -in "${manifest}" -sigfile "${signature}" >/dev/null 2>&1
}

if [[ ${version} == 2 ]]; then
  signing_key_id=$(jq -er '.signingKeyId | select(test("^[0-9a-f]{64}$"))' "${manifest}")
  verify_with_key "${keyring}/${signing_key_id}.pem" || {
    printf 'No matching retained public key verified manifest key %s.\n' \
      "${signing_key_id}" >&2
    exit 1
  }
else
  verified=false
  shopt -s nullglob
  for public_key in "${keyring}"/*.pem; do
    if verify_with_key "${public_key}"; then
      verified=true
      break
    fi
  done
  [[ ${verified} == true ]] || {
    printf 'No retained public key verified the legacy manifest.\n' >&2
    exit 1
  }
fi
printf 'Encrypted logical backup digest, size, and signature: verified.\n'
