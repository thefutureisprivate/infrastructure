#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
application_lock="${repo_root}/Ansible/compose.yaml"
tool_lock="${repo_root}/Tools/compose.yaml"
offline=false

if [[ ${1:-} == "--offline" ]]; then
  offline=true
elif (($# > 0)); then
  printf 'Usage: %s [--offline]\n' "$0" >&2
  exit 2
fi

mapfile -t application_images < <(
  sed -nE 's/^[[:space:]]*image:[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
    "${application_lock}"
)
mapfile -t tool_images < <(
  sed -nE 's/^[[:space:]]*image:[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
    "${tool_lock}"
)

if ((${#application_images[@]} != 3)); then
  printf 'Expected exactly three image pins in %s, found %d\n' \
    "${application_lock}" "${#application_images[@]}" >&2
  exit 1
fi
if ((${#tool_images[@]} != 3)); then
  printf 'Expected exactly three image pins in %s, found %d\n' \
    "${tool_lock}" "${#tool_images[@]}" >&2
  exit 1
fi

stalwart_image=''
stalwart_cli_image=''
postgres_image=''
for image_ref in "${application_images[@]}"; do
  case "${image_ref}" in
    docker.io/stalwartlabs/stalwart:*)
      stalwart_image=${image_ref}
      ;;
    docker.io/stalwartlabs/cli:*)
      stalwart_cli_image=${image_ref}
      ;;
    docker.io/library/postgres:*)
      postgres_image=${image_ref}
      ;;
    *)
      printf 'Unapproved image repository in %s: %s\n' \
        "${application_lock}" "${image_ref}" >&2
      exit 1
      ;;
  esac
done

butane_image=''
coreos_installer_image=''
hcloud_uploader_image=''
for image_ref in "${tool_images[@]}"; do
  case "${image_ref}" in
    quay.io/coreos/butane:*)
      butane_image=${image_ref}
      ;;
    quay.io/coreos/coreos-installer:*)
      coreos_installer_image=${image_ref}
      ;;
    ghcr.io/apricote/hcloud-upload-image:*)
      hcloud_uploader_image=${image_ref}
      ;;
    *)
      printf 'Unapproved image repository in %s: %s\n' \
        "${tool_lock}" "${image_ref}" >&2
      exit 1
      ;;
  esac
done

stalwart_pattern='^docker\.io/stalwartlabs/stalwart:(v[0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$'
stalwart_cli_pattern='^docker\.io/stalwartlabs/cli:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$'
postgres_pattern='^docker\.io/library/postgres:[0-9]+\.[0-9]+-alpine@sha256:[0-9a-f]{64}$'
butane_pattern='^quay\.io/coreos/butane:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
coreos_installer_pattern='^quay\.io/coreos/coreos-installer:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
hcloud_uploader_pattern='^ghcr\.io/apricote/hcloud-upload-image:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'

if [[ ! ${stalwart_image} =~ ${stalwart_pattern} ]]; then
  printf 'Stalwart must use an exact vMAJOR.MINOR.PATCH tag and sha256 digest\n' >&2
  exit 1
fi
stalwart_tag=${BASH_REMATCH[1]}

if [[ ! ${stalwart_cli_image} =~ ${stalwart_cli_pattern} ]]; then
  printf 'Stalwart CLI must use an exact MAJOR.MINOR.PATCH tag and sha256 digest\n' >&2
  exit 1
fi
stalwart_cli_tag=${BASH_REMATCH[1]}

if [[ ! ${postgres_image} =~ ${postgres_pattern} ]]; then
  printf 'PostgreSQL must use an exact MAJOR.MINOR-alpine tag and sha256 digest\n' >&2
  exit 1
fi
if [[ ! ${butane_image} =~ ${butane_pattern} ]]; then
  printf 'Butane must use an exact vMAJOR.MINOR.PATCH tag and sha256 digest\n' >&2
  exit 1
fi
if [[ ! ${coreos_installer_image} =~ ${coreos_installer_pattern} ]]; then
  printf 'coreos-installer must use an exact vMAJOR.MINOR.PATCH tag and sha256 digest\n' >&2
  exit 1
fi
if [[ ! ${hcloud_uploader_image} =~ ${hcloud_uploader_pattern} ]]; then
  printf 'hcloud-upload-image must use an exact vMAJOR.MINOR.PATCH tag and sha256 digest\n' >&2
  exit 1
fi

printf 'Container image references: pinned and repository-scoped\n'

if [[ ${offline} == true ]]; then
  printf 'Provenance verification: skipped in offline mode\n'
  exit 0
fi

if ! command -v cosign >/dev/null 2>&1; then
  printf 'cosign is required for online provenance verification\n' >&2
  exit 1
fi

oidc_issuer='https://token.actions.githubusercontent.com'

verify_signed_image() {
  local image_ref=$1 certificate_identity=$2

  cosign verify \
    --certificate-identity "${certificate_identity}" \
    --certificate-oidc-issuer "${oidc_issuer}" \
    "${image_ref}" >/dev/null

  cosign verify-attestation \
    --type https://slsa.dev/provenance/v1 \
    --certificate-identity "${certificate_identity}" \
    --certificate-oidc-issuer "${oidc_issuer}" \
    "${image_ref}" >/dev/null
}

verify_signed_image \
  "${stalwart_image}" \
  "https://github.com/stalwartlabs/stalwart/.github/workflows/ci.yml@refs/tags/${stalwart_tag}"
verify_signed_image \
  "${stalwart_cli_image}" \
  "https://github.com/stalwartlabs/cli/.github/workflows/release.yml@refs/tags/v${stalwart_cli_tag}"

printf 'Stalwart provenance: verified signature, Rekor entry, and SLSA provenance\n'
printf 'Stalwart CLI provenance: verified signature, Rekor entry, and SLSA provenance\n'
printf 'PostgreSQL provenance: digest-only exception; upstream image is not signed\n'
printf 'CoreOS and hcloud deployment tools: exact release tags and immutable digests verified\n'
