#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
compose_file="${repo_root}/Ansible/compose.yaml"
plan_file="${repo_root}/Stalwart/hardening.ndjson"
runtime=${STALWART_CLI_RUNTIME:-}
stalwart_url=${STALWART_URL:-http://127.0.0.1:8080}
stalwart_user=${STALWART_USER:-admin}

for command_name in jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required\n' "${command_name}" >&2
    exit 1
  }
done
if [[ ${stalwart_url} != http://127.0.0.1:8080 ]]; then
  printf 'Bootstrap is restricted to http://127.0.0.1:8080 through the SSH tunnel.\n' >&2
  exit 2
fi
if [[ -z ${STALWART_PASSWORD:-} ]]; then
  if [[ ! -t 0 ]]; then
    printf 'Set STALWART_PASSWORD or run from an interactive terminal.\n' >&2
    exit 2
  fi
  read -r -s -p 'Temporary Stalwart bootstrap password: ' STALWART_PASSWORD
  printf '\n'
fi
if [[ -z ${STALWART_PASSWORD} ]]; then
  printf 'The bootstrap password cannot be empty.\n' >&2
  exit 2
fi

if [[ -z ${runtime} ]]; then
  if command -v podman >/dev/null 2>&1; then
    runtime=podman
  elif command -v docker >/dev/null 2>&1; then
    runtime=docker
  else
    printf 'Podman or Docker is required to run the pinned Stalwart CLI.\n' >&2
    exit 1
  fi
fi
if [[ ${runtime} != podman && ${runtime} != docker ]]; then
  printf 'STALWART_CLI_RUNTIME must be podman or docker.\n' >&2
  exit 2
fi

mapfile -t cli_images < <(
  sed -nE 's/^[[:space:]]*image:[[:space:]]*"(docker\.io\/stalwartlabs\/cli:[^"]+)"[[:space:]]*$/\1/p' \
    "${compose_file}"
)
if ((${#cli_images[@]} != 1)); then
  printf 'Expected exactly one pinned Stalwart CLI image.\n' >&2
  exit 1
fi
cli_image=${cli_images[0]}

export STALWART_URL=${stalwart_url}
export STALWART_USER=${stalwart_user}
export STALWART_PASSWORD
trap 'unset STALWART_PASSWORD STALWART_USER STALWART_URL' EXIT HUP INT TERM

run_cli() {
  "${runtime}" run --rm --interactive --read-only --network host \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
    --env XDG_CACHE_HOME=/tmp/cache \
    --env STALWART_URL \
    --env STALWART_USER \
    --env STALWART_PASSWORD \
    "${cli_image}" --no-color "$@"
}

application_plan=$(jq -c \
  'select(."@type" == "reconcile" and .object == "Application")' \
  "${plan_file}")
if [[ -z ${application_plan} ]]; then
  printf 'The hardening plan has no Application reconciliation.\n' >&2
  exit 1
fi

run_cli apply --stdin --dry-run <<<"${application_plan}"
run_cli apply --stdin --json <<<"${application_plan}"
run_cli query Application \
  --fields enabled,description,resourceUrl,urlPrefix,autoUpdateFrequency,unpackDirectory,oauthClientId \
  --json |
  jq -e -s '
    length == 1
    and .[0].enabled == true
    and .[0].description == "Stalwart Web Interface"
    and .[0].resourceUrl == "file:///opt/stalwart-webui/webui.zip"
    and (.[0].urlPrefix | keys | sort) == ["/account", "/admin"]
  ' >/dev/null

printf 'Verified local Stalwart Web UI is active; opening /admin is now safe.\n'
