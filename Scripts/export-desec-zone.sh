#!/usr/bin/env bash
set -euo pipefail

domain=${1:-}

if [[ -z "${domain}" ]] || [[ ! "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
  printf 'Usage: %s <dns-zone>\n' "$0" >&2
  exit 2
fi
if [[ -z "${DESEC_API_TOKEN:-}" ]]; then
  printf '%s\n' "DESEC_API_TOKEN is required." >&2
  exit 2
fi

printf 'header = "Authorization: Token %s"\n' "${DESEC_API_TOKEN}" | \
  curl \
    --config - \
    --fail \
    --proto '=https' \
    --silent \
    --show-error \
    --tlsv1.2 \
    --url "https://desec.io/api/v1/domains/${domain}/rrsets/" | \
  jq --sort-keys '.'
