#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
compose_file="${repo_root}/Ansible/compose.yaml"
plan_file="${repo_root}/Stalwart/hardening.ndjson"
mta_sts_plan_file="${repo_root}/Stalwart/mta-sts.ndjson"
stalwart_url=${STALWART_URL:-https://mail.thefutureisprivate.dev}
mta_sts_url=${MTA_STS_URL:-https://mta-sts.thefutureisprivate.dev/.well-known/mta-sts.txt}
runtime=${STALWART_CLI_RUNTIME:-}
runtime_token_secret=''

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  unset STALWART_CONFIG_API_TOKEN STALWART_TOKEN STALWART_URL
  if [[ -n ${runtime_token_secret} ]]; then
    if ! container_engine podman secret rm "${runtime_token_secret}" >/dev/null 2>&1; then
      printf 'Failed to remove transient Podman secret %s; remove it manually.\n' \
        "${runtime_token_secret}" >&2
      status=1
    fi
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
if [[ ${mta_sts_url} != https://* ]]; then
  printf 'MTA_STS_URL must use https://; refusing cleartext policy verification\n' >&2
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

container_engine() {
  local engine=$1
  shift
  if [[ ${engine} == podman && -n ${CONTAINER_ID:-} ]] && \
    command -v distrobox-host-exec >/dev/null 2>&1; then
    distrobox-host-exec podman "$@"
  else
    "${engine}" "$@"
  fi
}

if ! container_engine "${runtime}" info >/dev/null 2>&1; then
  if [[ ${runtime} == podman && -n ${CONTAINER_ID:-} ]]; then
    printf 'The host Podman engine is unreachable through distrobox-host-exec.\n' >&2
  else
    printf '%s is installed but its container service is unreachable.\n' "${runtime}" >&2
  fi
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

if [[ ${runtime} == podman ]]; then
  token_secret_id=$(openssl rand -hex 16)
  if [[ ! ${token_secret_id} =~ ^[0-9a-f]{32}$ ]]; then
    printf 'OpenSSL did not generate the expected token-secret identifier.\n' >&2
    exit 1
  fi
  runtime_token_secret="stalwart-hardening-token-${token_secret_id}"
  if ! printf '%s' "${STALWART_CONFIG_API_TOKEN}" | \
    container_engine podman secret create "${runtime_token_secret}" - >/dev/null; then
    runtime_token_secret=''
    printf 'Failed to create the transient host-Podman API-token secret.\n' >&2
    exit 1
  fi
  unset STALWART_CONFIG_API_TOKEN
else
  export STALWART_TOKEN=${STALWART_CONFIG_API_TOKEN}
  unset STALWART_CONFIG_API_TOKEN
fi

run_cli() {
  local -a container_args=(
    run
    --rm
    --interactive
    --read-only
    --cap-drop=all
    --security-opt=no-new-privileges
    "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777"
    --env XDG_CACHE_HOME=/tmp/cache
    --env "STALWART_URL=${STALWART_URL}"
  )
  if [[ ${runtime} == podman ]]; then
    container_args+=(
      --secret "${runtime_token_secret},type=env,target=STALWART_TOKEN"
    )
  else
    container_args+=(--env STALWART_TOKEN)
  fi
  container_args+=("${cli_image}" --no-color "$@")
  container_engine "${runtime}" "${container_args[@]}"
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
expected_inbound_throttles=$(jq -cS -s '
  map(select(."@type" == "upsert" and .object == "MtaInboundThrottle"))[0]
    .value | [.[] | {enable, description, key, match, rate}]
    | sort_by(.description)
' "${plan_file}")
expected_queue_quotas=$(jq -cS -s '
  map(select(."@type" == "upsert" and .object == "MtaQueueQuota"))[0]
    .value | [.[] | {enable, description, key, match, messages, size}]
    | sort_by(.description)
' "${plan_file}")
expected_http=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "Http"))[0].value
' "${plan_file}")
expected_imap=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "Imap"))[0].value
' "${plan_file}")
expected_jmap=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "Jmap"))[0].value
' "${plan_file}")
expected_authentication=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "Authentication"))[0].value
' "${plan_file}")
expected_webdav=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "WebDav"))[0].value
' "${plan_file}")
expected_auth=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "MtaStageAuth"))[0].value
' "${plan_file}")
expected_mail=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "MtaStageMail"))[0].value
' "${plan_file}")
expected_mta_sts=$(jq -cS -s '
  map(select(."@type" == "update" and .object == "MtaSts"))[0].value
' "${mta_sts_plan_file}")
expected_applications=$(jq -cS -s '
  def managed: {
    enabled, description, resourceUrl, urlPrefix,
    autoUpdateFrequency, unpackDirectory, oauthClientId
  };
  map(select(."@type" == "reconcile" and .object == "Application"))[0]
    .value | [.[] | managed] | sort_by(.description)
' "${plan_file}")

actual_listeners=''
actual_inbound_throttles=''
actual_queue_quotas=''
actual_http=''
actual_imap=''
actual_jmap=''
actual_authentication=''
actual_webdav=''
actual_auth=''
actual_mail=''
actual_mta_sts=''
actual_applications=''

read_actual_configuration() {
  local listener_ndjson inbound_throttle_ndjson queue_quota_ndjson http_json imap_json jmap_json authentication_json webdav_json auth_json mail_json mta_sts_json application_ndjson

  listener_ndjson=$(run_cli query NetworkListener \
    --fields name,bind,protocol,overrideProxyTrustedNetworks,useTls,tlsDisableCipherSuites,tlsDisableProtocols,tlsIgnoreClientOrder,tlsImplicit,tlsTimeout,maxConnections \
    --json) || return 1
  inbound_throttle_ndjson=$(run_cli query MtaInboundThrottle \
    --fields enable,description,key,match,rate \
    --json) || return 1
  queue_quota_ndjson=$(run_cli query MtaQueueQuota \
    --fields enable,description,key,match,messages,size \
    --json) || return 1
  http_json=$(run_cli get Http --fields \
    rateLimitAuthenticated,rateLimitAnonymous,enableHsts,usePermissiveCors,responseHeaders,useXForwarded,redirectRoot \
    --json) || return 1
  imap_json=$(run_cli get Imap --fields \
    maxConcurrent,maxRequestRate,maxRequestSize \
    --json) || return 1
  jmap_json=$(run_cli get Jmap --fields \
    maxConcurrentRequests,maxRequestSize,maxMethodCalls \
    --json) || return 1
  authentication_json=$(run_cli get Authentication --fields \
    passwordHashAlgorithm,passwordMinLength,passwordMinStrength,maxApiKeys,maxAppPasswords \
    --json) || return 1
  webdav_json=$(run_cli get WebDav --fields \
    enableAssistedDiscovery,maxLockTimeout,maxLocks,deadPropertyMaxSize,livePropertyMaxSize,requestMaxSize,maxResults \
    --json) || return 1
  auth_json=$(run_cli get MtaStageAuth --fields \
    maxFailures,waitOnFail,saslMechanisms,mustMatchSender,require \
    --json) || return 1
  mail_json=$(run_cli get MtaStageMail --fields \
    isSenderAllowed \
    --json) || return 1
  mta_sts_json=$(run_cli get MtaSts --fields \
    mode,maxAge,mxHosts \
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
  actual_inbound_throttles=$(jq -cS -s \
    --argjson expected "${expected_inbound_throttles}" '
    def normalize_conditionals:
      walk(if type == "object" and .match? == {} then del(.match) else . end);
    ($expected | map(.description)) as $owned_descriptions
    | [.[]
      | select(.description as $description | $owned_descriptions | index($description))
      | {enable, description, key, match, rate}]
    | sort_by(.description)
    | normalize_conditionals
  ' <<<"${inbound_throttle_ndjson}")
  actual_queue_quotas=$(jq -cS -s \
    --argjson expected "${expected_queue_quotas}" '
    def normalize_conditionals:
      walk(if type == "object" and .match? == {} then del(.match) else . end);
    ($expected | map(.description)) as $owned_descriptions
    | [.[]
      | select(.description as $description | $owned_descriptions | index($description))
      | {enable, description, key, match, messages, size}]
    | sort_by(.description)
    | normalize_conditionals
  ' <<<"${queue_quota_ndjson}")
  actual_http=$(jq -cS '{
    rateLimitAuthenticated, rateLimitAnonymous, enableHsts,
    usePermissiveCors, responseHeaders, useXForwarded, redirectRoot
  }' <<<"${http_json}")
  actual_imap=$(jq -cS '{
    maxConcurrent, maxRequestRate, maxRequestSize
  }' <<<"${imap_json}")
  actual_jmap=$(jq -cS '{
    maxConcurrentRequests, maxRequestSize, maxMethodCalls
  }' <<<"${jmap_json}")
  actual_authentication=$(jq -cS '{
    passwordHashAlgorithm, passwordMinLength, passwordMinStrength,
    maxApiKeys, maxAppPasswords
  }' <<<"${authentication_json}")
  actual_webdav=$(jq -cS '{
    enableAssistedDiscovery, maxLockTimeout, maxLocks, deadPropertyMaxSize,
    livePropertyMaxSize, requestMaxSize, maxResults
  }' <<<"${webdav_json}")
  actual_auth=$(jq -cS '
    def normalize_conditionals:
      walk(if type == "object" and .match? == {} then del(.match) else . end);
    {maxFailures, waitOnFail, saslMechanisms, mustMatchSender, require}
    | normalize_conditionals
  ' <<<"${auth_json}")
  actual_mail=$(jq -cS '
    def normalize_conditionals:
      walk(if type == "object" and .match? == {} then del(.match) else . end);
    {isSenderAllowed} | normalize_conditionals
  ' <<<"${mail_json}")
  actual_mta_sts=$(jq -cS '{mode, maxAge, mxHosts}' <<<"${mta_sts_json}")
  actual_applications=$(jq -cS -s '
    map({
      enabled, description, resourceUrl, urlPrefix,
      autoUpdateFrequency, unpackDirectory, oauthClientId
    }) | sort_by(.description)
  ' <<<"${application_ndjson}")
}

configuration_matches() {
  [[ ${actual_listeners} == "${expected_listeners}" ]] &&
    [[ ${actual_inbound_throttles} == "${expected_inbound_throttles}" ]] &&
    [[ ${actual_queue_quotas} == "${expected_queue_quotas}" ]] &&
    [[ ${actual_http} == "${expected_http}" ]] &&
    [[ ${actual_imap} == "${expected_imap}" ]] &&
    [[ ${actual_jmap} == "${expected_jmap}" ]] &&
    [[ ${actual_authentication} == "${expected_authentication}" ]] &&
    [[ ${actual_webdav} == "${expected_webdav}" ]] &&
    [[ ${actual_auth} == "${expected_auth}" ]] &&
    [[ ${actual_mail} == "${expected_mail}" ]] &&
    [[ ${actual_mta_sts} == "${expected_mta_sts}" ]] &&
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

verify_live_mta_sts_policy() {
  local address_family policy
  for address_family in -4 -6; do
    policy=$(curl --fail --silent --show-error \
      "${address_family}" \
      --max-time 20 \
      --proto '=https' \
      --tlsv1.3 --tls-max 1.3 \
      "${mta_sts_url}") || return 1
    if ! awk '
      { sub(/\r$/, "") }
      $0 == "version: STSv1" { version++ }
      $0 == "mode: enforce" { mode++ }
      $0 == "max_age: 604800" { max_age++ }
      $0 == "mx: mail.thefutureisprivate.dev" { mx++ }
      END { exit(version == 1 && mode == 1 && max_age == 1 && mx == 1 ? 0 : 1) }
    ' <<<"${policy}"; then
      printf 'MTA-STS policy is not enforcing the expected MX over %s\n' \
        "${address_family}" >&2
      return 1
    fi
  done
  printf 'Enforcing MTA-STS policy over IPv4 and IPv6: verified\n'
}

verify_tls_policy() {
  local authority banner ehlo_complete ehlo_line host mail_response port smtp_fd starttls_advertised
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

  if ! exec {smtp_fd}<>"/dev/tcp/${host}/25"; then
    printf 'Unable to connect to SMTP federation endpoint %s:25\n' "${host}" >&2
    return 1
  fi
  if ! IFS= read -r -t 20 banner <&"${smtp_fd}" || [[ ${banner%$'\r'} != 220\ * ]]; then
    printf 'SMTP federation endpoint %s:25 returned an invalid greeting\n' "${host}" >&2
    exec {smtp_fd}>&-
    return 1
  fi
  printf 'EHLO tls-policy-audit.invalid\r\n' >&"${smtp_fd}"
  ehlo_complete=false
  starttls_advertised=false
  while IFS= read -r -t 20 ehlo_line <&"${smtp_fd}"; do
    ehlo_line=${ehlo_line%$'\r'}
    if [[ ${ehlo_line} == 250-*STARTTLS* || ${ehlo_line} == '250 STARTTLS' ]]; then
      starttls_advertised=true
    fi
    if [[ ${ehlo_line} == 250\ * ]]; then
      ehlo_complete=true
      break
    fi
    if [[ ${ehlo_line} != 250-* ]]; then
      printf 'SMTP federation endpoint %s:25 returned an invalid EHLO response\n' "${host}" >&2
      exec {smtp_fd}>&-
      return 1
    fi
  done
  if [[ ${ehlo_complete} != true ]]; then
    printf 'SMTP federation endpoint %s:25 did not complete its EHLO response\n' "${host}" >&2
    exec {smtp_fd}>&-
    return 1
  fi
  if [[ ${starttls_advertised} != true ]]; then
    printf 'SMTP federation endpoint %s:25 did not advertise STARTTLS\n' "${host}" >&2
    exec {smtp_fd}>&-
    return 1
  fi
  printf 'MAIL FROM:<>\r\n' >&"${smtp_fd}"
  if ! IFS= read -r -t 20 mail_response <&"${smtp_fd}"; then
    printf 'SMTP federation endpoint %s:25 did not answer a plaintext MAIL command\n' "${host}" >&2
    exec {smtp_fd}>&-
    return 1
  fi
  mail_response=${mail_response%$'\r'}
  printf 'QUIT\r\n' >&"${smtp_fd}" || true
  exec {smtp_fd}>&-
  if [[ ${mail_response} != [45][0-9][0-9]\ * ]]; then
    printf 'SMTP federation endpoint %s:25 accepted plaintext MAIL: %s\n' \
      "${host}" "${mail_response}" >&2
    return 1
  fi

  printf 'Client TLS 1.3 floor and mandatory SMTP STARTTLS with TLS 1.2 compatibility: verified\n'
}

audit() {
  read_actual_configuration
  if ! configuration_matches; then
    show_drift NetworkListener "${expected_listeners}" "${actual_listeners}"
    show_drift MtaInboundThrottle "${expected_inbound_throttles}" "${actual_inbound_throttles}"
    show_drift MtaQueueQuota "${expected_queue_quotas}" "${actual_queue_quotas}"
    show_drift Http "${expected_http}" "${actual_http}"
    show_drift Imap "${expected_imap}" "${actual_imap}"
    show_drift Jmap "${expected_jmap}" "${actual_jmap}"
    show_drift Authentication "${expected_authentication}" "${actual_authentication}"
    show_drift WebDav "${expected_webdav}" "${actual_webdav}"
    show_drift MtaStageAuth "${expected_auth}" "${actual_auth}"
    show_drift MtaStageMail "${expected_mail}" "${actual_mail}"
    show_drift MtaSts "${expected_mta_sts}" "${actual_mta_sts}"
    show_drift Application "${expected_applications}" "${actual_applications}"
    return 1
  fi

  printf 'Stalwart declarative hardening: in sync\n'
  verify_live_http_headers
  verify_live_mta_sts_policy
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
  verify_live_mta_sts_policy
  verify_live_dav_endpoints
  verify_tls_policy
  exit
fi

run_cli apply --stdin --dry-run <"${plan_file}"
run_cli apply --stdin --json <"${plan_file}"
run_cli apply --stdin --dry-run <"${mta_sts_plan_file}"
run_cli apply --stdin --json <"${mta_sts_plan_file}"
run_cli create Action/ReloadSettings >/dev/null
audit
