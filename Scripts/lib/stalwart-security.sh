#!/usr/bin/env bash

# Shared trust-boundary checks for Stalwart controller workflows. Callers must
# enable their own strict shell options before sourcing this file.

stalwart_podman() {
  if [[ -n ${CONTAINER_ID:-} ]] && command -v distrobox-host-exec >/dev/null 2>&1; then
    distrobox-host-exec podman --remote=false "$@"
  else
    podman --remote=false "$@"
  fi
}

stalwart_require_local_podman() {
  local variable_name

  for variable_name in \
    CONTAINER_CONNECTION CONTAINER_HOST DOCKER_CONTEXT DOCKER_HOST; do
    if [[ -n ${!variable_name:-} ]]; then
      printf '%s must be unset; Stalwart credentials may only enter direct local Podman.\n' \
        "${variable_name}" >&2
      return 1
    fi
  done
  if [[ -n ${STALWART_CLI_RUNTIME:-} && ${STALWART_CLI_RUNTIME} != podman ]]; then
    printf 'STALWART_CLI_RUNTIME may only select podman.\n' >&2
    return 1
  fi
  if ! command -v podman >/dev/null 2>&1; then
    printf 'Podman is required to run the pinned Stalwart CLI.\n' >&2
    return 1
  fi
  if ! stalwart_podman info >/dev/null 2>&1; then
    if [[ -n ${CONTAINER_ID:-} ]]; then
      printf 'Direct local host Podman is unreachable through distrobox-host-exec.\n' >&2
    else
      printf 'Direct local Podman is unavailable.\n' >&2
    fi
    return 1
  fi
}

stalwart_mta_sts_policy_matches() {
  local expected_mx=$1 policy=$2

  awk -v expected_mx="mx: ${expected_mx}" '
    BEGIN { valid = 1 }
    { sub(/\r$/, "") }
    $0 == "" { next }
    $0 == "version: STSv1" { version++; next }
    $0 == "mode: enforce" { mode++; next }
    $0 == "max_age: 604800" { max_age++; next }
    $0 == expected_mx { mx++; next }
    /^version:[[:space:]]*/ || /^mode:[[:space:]]*/ ||
      /^max_age:[[:space:]]*/ || /^mx:[[:space:]]*/ { valid = 0; next }
    /^[A-Za-z0-9_-]+:[[:space:]].*$/ { next }
    { valid = 0 }
    END {
      exit(valid && version == 1 && mode == 1 && max_age == 1 && mx == 1 ? 0 : 1)
    }
  ' <<<"${policy}"
}
