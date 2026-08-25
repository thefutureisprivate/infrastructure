#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
compose_file="${repo_root}/Ansible/compose.yaml"
plan_file="${repo_root}/Stalwart/hardening.ndjson"
stalwart_url=${STALWART_URL:-https://mail.thefutureisprivate.dev}
runtime=${STALWART_CLI_RUNTIME:-}

usage() {
  printf 'Usage: %s apply|audit\n' "$0" >&2
}

if (($# != 1)); then
  usage
  exit 2
fi
mode=$1
if [[ ${mode} != apply && ${mode} != audit ]]; then
  usage
  exit 2
fi

for command_name in jq curl openssl timeout; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf '%s is required\n' "${command_name}" >&2
    exit 1
  fi
done

if [[ ${stalwart_url} != https://* ]]; then
  printf 'STALWART_URL must use https://; refusing cleartext administration\n' >&2
  exit 1
fi
if [[ -z ${STALWART_CONFIG_API_TOKEN:-} ]]; then
  printf 'STALWART_CONFIG_API_TOKEN is required\n' >&2
  exit 1
fi
if [[ ${STALWART_CONFIG_API_TOKEN} == replace-* ]]; then
  printf 'STALWART_CONFIG_API_TOKEN still contains the example placeholder\n' >&2
  exit 1
fi

if [[ -z ${runtime} ]]; then
  if command -v podman >/dev/null 2>&1; then
    runtime=podman
  elif command -v docker >/dev/null 2>&1; then
    runtime=docker
  else
    printf 'Podman or Docker is required to run the pinned Stalwart CLI\n' >&2
    exit 1
  fi
fi
if [[ ${runtime} != podman && ${runtime} != docker ]]; then
  printf 'STALWART_CLI_RUNTIME must be podman or docker\n' >&2
  exit 1
fi
if ! command -v "${runtime}" >/dev/null 2>&1; then
  printf 'Configured container runtime is unavailable: %s\n' "${runtime}" >&2
  exit 1
fi

mapfile -t cli_images < <(
  sed -nE 's/^[[:space:]]*image:[[:space:]]*"(docker\.io\/stalwartlabs\/cli:[^"]+)"[[:space:]]*$/\1/p' \
    "${compose_file}"
)
if ((${#cli_images[@]} != 1)); then
  printf 'Expected exactly one Stalwart CLI image pin in %s\n' "${compose_file}" >&2
  exit 1
fi
cli_image=${cli_images[0]}

export STALWART_URL=${stalwart_url}
export STALWART_TOKEN=${STALWART_CONFIG_API_TOKEN}
unset STALWART_CONFIG_API_TOKEN

run_cli() {
  "${runtime}" run --rm --interactive --read-only \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
    --env XDG_CACHE_HOME=/tmp/cache \
    --env STALWART_URL \
    --env STALWART_TOKEN \
    "${cli_image}" --no-color "$@"
}

expected_listeners=$(jq -cS -s '
  def managed: {
    name, bind, protocol, overrideProxyTrustedNetworks, useTls,
    tlsDisableCipherSuites, tlsDisableProtocols, tlsIgnoreClientOrder,
    tlsImplicit, tlsTimeout, maxConnections
  };
  map(select(."@type" == "reconcile" and .object == "NetworkListener"))[0]
    .value | [.[] | managed] | sort_by(.name)
' "${plan_file}")
expected_http=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "Http"))[0].value
' "${plan_file}")
expected_webdav=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "WebDav"))[0].value
' "${plan_file}")
expected_auth=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "MtaStageAuth"))[0].value
' "${plan_file}")
expected_applications=$(jq -cS -s '
  def managed: {
    enabled, description, resourceUrl, urlPrefix,
    autoUpdateFrequency, unpackDirectory, oauthClientId
  };
  map(select(."@type" == "reconcile" and .object == "Application"))[0]
    .value | [.[] | managed] | sort_by(.description)
' "${plan_file}")

actual_listeners=''
actual_http=''
actual_webdav=''
actual_auth=''
actual_applications=''

read_actual_configuration() {
  local listener_ndjson http_json webdav_json auth_json application_ndjson

  listener_ndjson=$(run_cli query NetworkListener \
    --fields name,bind,protocol,overrideProxyTrustedNetworks,useTls,tlsDisableCipherSuites,tlsDisableProtocols,tlsIgnoreClientOrder,tlsImplicit,tlsTimeout,maxConnections \
    --json) || return 1
  http_json=$(run_cli get Http --fields \
    rateLimitAuthenticated,rateLimitAnonymous,enableHsts,usePermissiveCors,responseHeaders,useXForwarded,redirectRoot \
    --json) || return 1
  webdav_json=$(run_cli get WebDav --fields \
    enableAssistedDiscovery,maxLockTimeout,maxLocks,deadPropertyMaxSize,livePropertyMaxSize,requestMaxSize,maxResults \
    --json) || return 1
  auth_json=$(run_cli get MtaStageAuth --fields \
    maxFailures,waitOnFail,saslMechanisms,mustMatchSender,require \
    --json) || return 1
  application_ndjson=$(run_cli query Application --fields \
    enabled,description,resourceUrl,urlPrefix,autoUpdateFrequency,unpackDirectory,oauthClientId \
    --json) || return 1

  actual_listeners=$(jq -cS -s '
    def managed: {
      name, bind, protocol, overrideProxyTrustedNetworks, useTls,
      tlsDisableCipherSuites, tlsDisableProtocols, tlsIgnoreClientOrder,
      tlsImplicit, tlsTimeout, maxConnections
    };
    [.[] | managed] | sort_by(.name)
  ' <<<"${listener_ndjson}")
  actual_http=$(jq -cS '{
    rateLimitAuthenticated, rateLimitAnonymous, enableHsts,
    usePermissiveCors, responseHeaders, useXForwarded, redirectRoot
  }' <<<"${http_json}")
  actual_webdav=$(jq -cS '{
    enableAssistedDiscovery, maxLockTimeout, maxLocks, deadPropertyMaxSize,
    livePropertyMaxSize, requestMaxSize, maxResults
  }' <<<"${webdav_json}")
  actual_auth=$(jq -cS '{
    maxFailures, waitOnFail, saslMechanisms, mustMatchSender, require
  }' <<<"${auth_json}")
  actual_applications=$(jq -cS -s '
    map({
      enabled, description, resourceUrl, urlPrefix,
      autoUpdateFrequency, unpackDirectory, oauthClientId
    }) | sort_by(.description)
  ' <<<"${application_ndjson}")
}

configuration_matches() {
  [[ ${actual_listeners} == "${expected_listeners}" ]] &&
    [[ ${actual_http} == "${expected_http}" ]] &&
    [[ ${actual_webdav} == "${expected_webdav}" ]] &&
    [[ ${actual_auth} == "${expected_auth}" ]] &&
    [[ ${actual_applications} == "${expected_applications}" ]]
}

show_drift() {
  local label=$1 expected=$2 actual=$3
  if [[ ${expected} == "${actual}" ]]; then
    return
  fi
  printf '%s configuration drift:\n' "${label}" >&2
  diff -u \
    <(jq -S '.' <<<"${expected}") \
    <(jq -S '.' <<<"${actual}") >&2 || true
}

verify_live_http_headers() {
  local headers header_name
  headers=$(curl --fail --silent --show-error \
    --max-time 20 \
    --dump-header - \
    --output /dev/null \
    "${STALWART_URL}/")

  for header_name in \
    cache-control \
    content-security-policy \
    cross-origin-opener-policy \
    cross-origin-resource-policy \
    expires \
    origin-agent-cluster \
    permissions-policy \
    pragma \
    referrer-policy \
    strict-transport-security \
    x-content-type-options \
    x-dns-prefetch-control \
    x-download-options \
    x-frame-options \
    x-permitted-cross-domain-policies \
    x-xss-protection; do
    if ! awk -v wanted="${header_name}" '
      BEGIN { IGNORECASE = 1; found = 0 }
      index($0, wanted ":") == 1 { found = 1 }
      END { exit(found ? 0 : 1) }
    ' <<<"${headers}"; then
      printf 'Live HTTPS response is missing %s\n' "${header_name}" >&2
      return 1
    fi
  done
  printf 'Live HTTPS security headers: verified\n'
}

verify_live_dav_endpoints() {
  local path status
  for path in /.well-known/caldav /.well-known/carddav /dav/file/; do
    status=$(curl --silent --show-error \
      --max-time 20 \
      --output /dev/null \
      --write-out '%{http_code}' \
      "${STALWART_URL}${path}")
    case ${status} in
      200|301|302|307|308|401)
        ;;
      *)
        printf 'DAV endpoint %s returned unexpected HTTP status %s\n' "${path}" "${status}" >&2
        return 1
        ;;
    esac
  done
  printf 'CalDAV, CardDAV, and WebDAV HTTPS endpoints: verified\n'
}

verify_tls_policy() {
  local authority host port
  authority=${STALWART_URL#https://}
  authority=${authority%%/*}
  host=${authority%%:*}
  if [[ -z ${host} || ${host} == \[* ]]; then
    printf 'STALWART_URL must contain a DNS hostname for TLS verification\n' >&2
    return 1
  fi

  for port in 443 465 993; do
    if ! timeout 20 openssl s_client \
      -connect "${host}:${port}" \
      -servername "${host}" \
      -tls1_3 \
      -verify_hostname "${host}" \
      -verify_return_error \
      -brief </dev/null >/dev/null 2>&1; then
      printf 'TLS 1.3 verification failed for client endpoint %s:%s\n' "${host}" "${port}" >&2
      return 1
    fi

    if timeout 20 openssl s_client \
      -connect "${host}:${port}" \
      -servername "${host}" \
      -tls1_2 \
      -brief </dev/null >/dev/null 2>&1; then
      printf 'Client endpoint %s:%s unexpectedly accepted TLS 1.2\n' "${host}" "${port}" >&2
      return 1
    fi
  done

  if ! timeout 20 openssl s_client \
    -starttls smtp \
    -connect "${host}:25" \
    -servername "${host}" \
    -tls1_2 \
    -verify_hostname "${host}" \
    -verify_return_error \
    -brief </dev/null >/dev/null 2>&1; then
    printf 'SMTP federation endpoint %s:25 did not accept TLS 1.2 STARTTLS\n' "${host}" >&2
    return 1
  fi

  printf 'Client TLS 1.3 floor and SMTP federation TLS 1.2 compatibility: verified\n'
}

audit() {
  read_actual_configuration
  if ! configuration_matches; then
    show_drift NetworkListener "${expected_listeners}" "${actual_listeners}"
    show_drift Http "${expected_http}" "${actual_http}"
    show_drift WebDav "${expected_webdav}" "${actual_webdav}"
    show_drift MtaStageAuth "${expected_auth}" "${actual_auth}"
    show_drift Application "${expected_applications}" "${actual_applications}"
    return 1
  fi

  printf 'Stalwart declarative hardening: in sync\n'
  verify_live_http_headers
  verify_live_dav_endpoints
  verify_tls_policy
}

if [[ ${mode} == audit ]]; then
  audit
  exit
fi

read_actual_configuration
if configuration_matches; then
  printf 'Stalwart declarative hardening: already in sync\n'
  verify_live_http_headers
  verify_live_dav_endpoints
  verify_tls_policy
  exit
fi

run_cli apply --stdin --dry-run <"${plan_file}"
run_cli apply --stdin --json <"${plan_file}"
audit
