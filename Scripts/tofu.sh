#!/usr/bin/env bash
set -euo pipefail

tofu_bin=${TOFU_BINARY:-tofu}
umask 077

command -v "${tofu_bin}" >/dev/null 2>&1 || {
  printf '%s is not installed.\n' "${tofu_bin}" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'jq is not installed.\n' >&2
  exit 1
}

tofu_working_directory=.
for argument in "$@"; do
  case ${argument} in
    -chdir=*) tofu_working_directory=${argument#-chdir=} ;;
  esac
done
if [[ ${tofu_working_directory} != /* ]]; then
  tofu_working_directory="${PWD}/${tofu_working_directory}"
fi
if [[ ! -d ${tofu_working_directory} ]]; then
  printf 'OpenTofu working directory does not exist: %s\n' \
    "${tofu_working_directory}" >&2
  exit 2
fi

is_plaintext_tofu_artifact() {
  local artifact=$1

  if [[ ${artifact} == *.tfplan ]]; then
    [[ $(LC_ALL=C od -An -N4 -tx1 -- "${artifact}" 2>/dev/null | tr -d ' \n') == 504b0304 ]]
  else
    jq -e 'type == "object" and (.version | type == "number")' \
      "${artifact}" >/dev/null 2>&1
  fi
}

plaintext_artifacts=()
while IFS= read -r -d '' artifact; do
  if is_plaintext_tofu_artifact "${artifact}"; then
    plaintext_artifacts+=("${artifact}")
  fi
done < <(
  find "${tofu_working_directory}" -maxdepth 1 -type f \
    \( -name '*.tfstate' -o -name '*.tfstate.*' -o -name '*.tfplan' \) -print0
)
if ((${#plaintext_artifacts[@]} > 0)); then
  printf 'Refusing OpenTofu while plaintext state or plan artifacts remain:\n' >&2
  printf '  %s\n' "${plaintext_artifacts[@]}" >&2
  printf 'Remove or securely quarantine these unsupported plaintext artifacts first.\n' >&2
  exit 1
fi

# OpenTofu's generic S3 backend reads AWS-compatible variable names, while the
# Scaleway provider reads SCW_* directly. Both receive the same SOPS-scoped
# operator credential without serializing it into backend.hcl.
if [[ -n ${SCW_ACCESS_KEY:-} || -n ${SCW_SECRET_KEY:-} ]]; then
  if [[ -z ${SCW_ACCESS_KEY:-} || -z ${SCW_SECRET_KEY:-} ]]; then
    printf 'SCW_ACCESS_KEY and SCW_SECRET_KEY must be supplied together.\n' >&2
    exit 2
  fi
  export AWS_ACCESS_KEY_ID=${SCW_ACCESS_KEY}
  export AWS_SECRET_ACCESS_KEY=${SCW_SECRET_KEY}
  unset AWS_SESSION_TOKEN
fi

state_passphrase=${TOFU_STATE_PASSPHRASE:-}
case ${state_passphrase} in
  replace-*|replace_with_*|*replace-with-at-least-32-random-characters*)
    printf 'TOFU_STATE_PASSPHRASE must not use a published example placeholder.\n' >&2
    exit 2
    ;;
esac
if (( ${#state_passphrase} < 32 )); then
  printf 'TOFU_STATE_PASSPHRASE must contain at least 32 characters.\n' >&2
  exit 2
fi

passphrase_literal=$(printf '%s' "${state_passphrase}" | jq -Rs .)
unset state_passphrase TOFU_STATE_PASSPHRASE

TF_ENCRYPTION=$(cat <<EOF
key_provider "pbkdf2" "infrastructure_state" {
  passphrase               = ${passphrase_literal}
  iterations               = 600000
  hash_function            = "sha512"
  encrypted_metadata_alias = "infrastructure-state-v1"
}
method "aes_gcm" "infrastructure_state" {
  keys = key_provider.pbkdf2.infrastructure_state
}
state {
  enforced = true
  method = method.aes_gcm.infrastructure_state
}
plan {
  enforced = true
  method   = method.aes_gcm.infrastructure_state
}
EOF
)

unset passphrase_literal
export TF_ENCRYPTION
exec "${tofu_bin}" "$@"
