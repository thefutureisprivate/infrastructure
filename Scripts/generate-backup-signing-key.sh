#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
mail_secrets_name=${SOPS_MAIL_FILE:-SOPS/mail.sops.yaml}
keyring_directory=${MAIL_BACKUP_SIGNING_KEYRING:-${repo_root}/SOPS/backup-signing-public-keys}
mode=${1:-register}
[[ ${mode} == register || ${mode} == --rotate ]] || {
  printf 'Usage: %s [--rotate]\n' "$0" >&2
  exit 2
}
case ${mail_secrets_name} in
  /*) mail_secrets_file=${mail_secrets_name} ;;
  *) mail_secrets_file="${repo_root}/${mail_secrets_name}" ;;
esac

for command_name in jq openssl sops; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is not installed.\n' "${command_name}" >&2
    exit 1
  }
done
if [[ ! -r ${mail_secrets_file} ]] || ! grep -q '^sops:' "${mail_secrets_file}"; then
  printf 'Encrypted mail secrets are missing or invalid: %s\n' "${mail_secrets_file}" >&2
  exit 2
fi

key_directory=$(mktemp -d "${TMPDIR:-/tmp}/mail-backup-signing.XXXXXX")
encrypted_work=$(mktemp "${mail_secrets_file}.XXXXXX")
cleanup() {
  rm -rf -- "${key_directory}"
  rm -f -- "${encrypted_work}"
}
trap cleanup EXIT HUP INT TERM

key_id() {
  openssl pkey -pubin -in "$1" -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}'
}

verify_pair() {
  local private_key=$1 public_key=$2
  openssl pkey -in "${private_key}" -pubout \
    -out "${key_directory}/derived-public.pem" >/dev/null 2>&1 || return 1
  openssl pkey -pubin -in "${public_key}" \
    -out "${key_directory}/normalized-public.pem" >/dev/null 2>&1 || return 1
  cmp -s "${key_directory}/derived-public.pem" \
    "${key_directory}/normalized-public.pem"
}

register_public_key() {
  local public_key=$1 id destination
  id=$(key_id "${public_key}")
  [[ ${id} =~ ^[0-9a-f]{64}$ ]] || return 1
  install -d -m 0755 "${keyring_directory}"
  destination="${keyring_directory}/${id}.pem"
  if [[ -e ${destination} ]]; then
    cmp -s "${public_key}" "${destination}" || {
      printf 'Public-key ID collision in %s.\n' "${destination}" >&2
      return 1
    }
  else
    install -m 0644 "${public_key}" "${destination}"
  fi
  printf '%s' "${id}"
}

existing_private="${key_directory}/existing-private.pem"
existing_public="${key_directory}/existing-public.pem"
have_existing=false
if ! sops decrypt --extract '["MAIL_BACKUP_SIGNING_PRIVATE_KEY"]' \
    "${mail_secrets_file}" >"${existing_private}" 2>/dev/null ||
   ! sops decrypt --extract '["MAIL_BACKUP_SIGNING_PUBLIC_KEY"]' \
    "${mail_secrets_file}" >"${existing_public}" 2>/dev/null; then
  printf 'Refusing to modify signing keys because the active fields could not be decrypted.\n' >&2
  exit 1
fi
if verify_pair "${existing_private}" "${existing_public}"; then
  have_existing=true
elif [[ $(<"${existing_private}") != replace-with-an-ed25519-private-key-in-pem-format ||
        $(<"${existing_public}") != replace-with-the-matching-ed25519-public-key-in-pem-format ]]; then
  printf 'Refusing to replace incomplete, invalid, or mismatched active signing material.\n' >&2
  exit 1
fi

if [[ ${mode} == register && ${have_existing} == true ]]; then
  existing_id=$(register_public_key "${existing_public}")
  printf 'Preserved the existing backup signing key and registered public key %s.\n' \
    "${existing_id}"
  exit 0
fi
if [[ ${mode} == --rotate && ${have_existing} != true ]]; then
  printf 'Refusing rotation because the encrypted active signing pair is missing or invalid.\n' >&2
  exit 1
fi

new_private="${key_directory}/private.pem"
new_public="${key_directory}/public.pem"
openssl genpkey -algorithm Ed25519 -out "${new_private}"
openssl pkey -in "${new_private}" -pubout -out "${new_public}"
verify_pair "${new_private}" "${new_public}"

if [[ ${have_existing} == true ]]; then
  old_id=$(register_public_key "${existing_public}")
fi
new_id=$(register_public_key "${new_public}")

# Work on an encrypted sibling and replace the original only after both fields
# decrypt to the new, matching pair. A failed second update cannot leave SOPS
# with mismatched active keys.
cp --preserve=mode -- "${mail_secrets_file}" "${encrypted_work}"
jq -Rs . <"${new_private}" |
  sops set --value-stdin "${encrypted_work}" '["MAIL_BACKUP_SIGNING_PRIVATE_KEY"]'
jq -Rs . <"${new_public}" |
  sops set --value-stdin "${encrypted_work}" '["MAIL_BACKUP_SIGNING_PUBLIC_KEY"]'
sops decrypt --extract '["MAIL_BACKUP_SIGNING_PRIVATE_KEY"]' \
  "${encrypted_work}" >"${key_directory}/verified-private.pem"
sops decrypt --extract '["MAIL_BACKUP_SIGNING_PUBLIC_KEY"]' \
  "${encrypted_work}" >"${key_directory}/verified-public.pem"
verify_pair "${key_directory}/verified-private.pem" \
  "${key_directory}/verified-public.pem"
mv -- "${encrypted_work}" "${mail_secrets_file}"

if [[ ${mode} == --rotate ]]; then
  printf 'Rotated backup signing key %s to %s; both public keys remain verifiable.\n' \
    "${old_id}" "${new_id}"
else
  printf 'Stored backup signing key %s and its public verification key.\n' "${new_id}"
fi
