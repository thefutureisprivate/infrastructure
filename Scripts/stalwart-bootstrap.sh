#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
# shellcheck source=Scripts/lib/stalwart-security.sh
source "${script_dir}/lib/stalwart-security.sh"
compose_file="${repo_root}/Ansible/compose.yaml"
inventory_file=${ANSIBLE_INVENTORY:-"${repo_root}/Ansible/inventory/hosts.yml"}
known_hosts_file=${ANSIBLE_KNOWN_HOSTS:-"${repo_root}/Ansible/inventory/known_hosts"}
initial_plan="${repo_root}/Stalwart/bootstrap-initial.ndjson"
staging_plan="${repo_root}/Stalwart/bootstrap-staging.ndjson"
production_plan="${repo_root}/Stalwart/bootstrap-production.ndjson"
mta_sts_plan="${repo_root}/Stalwart/mta-sts.ndjson"
tf_dir=${TF_DIR:-OpenTofu}
tf_vars=${TF_VARS:-terraform.tfvars}
tofu_bin=${TOFU:-tofu}
sops_infrastructure_file=${SOPS_INFRASTRUCTURE_FILE:-SOPS/infrastructure.sops.yaml}
authority_vars_name=${STALWART_AUTHORITY_VARS:-stalwart-authority.tfvars.json}
stalwart_domain=thefutureisprivate.dev
stalwart_hostname=mail.thefutureisprivate.dev
stalwart_autoconfig_hostname=autoconfig.thefutureisprivate.dev
stalwart_autodiscover_hostname=autodiscover.thefutureisprivate.dev
stalwart_ua_autoconfig_hostname=ua-auto-config.thefutureisprivate.dev
staging_acme_directory=https://acme-staging-v02.api.letsencrypt.org/directory
production_acme_directory=https://acme-v02.api.letsencrypt.org/directory
bootstrap_pending_description='Primary mail domain (staged enrollment pending)'
stalwart_inventory_host=${STALWART_INVENTORY_HOST:-mail-01}
stalwart_user='admin'
stalwart_password=''
unset STALWART_PASSWORD STALWART_USER
local_port=''
bootstrap_tls=false
ssh_control_dir=''
ssh_control_socket=''
cleanup_deployment=false
tofu_plan=''
runtime_password_secret=''
remote_password_secret=''
remote_password_secret_created=false
bootstrap_stage='local preflight'
ssh_options=()
ssh_target=''
production_refresh_started_at=''
mail_dns_refresh_started_at=''

if (($# != 0)); then
  printf 'Usage: %s\n' "${0##*/}" >&2
  exit 2
fi

cleanup() {
  local status=$?
  local production_restored=false
  trap - EXIT HUP INT TERM
  unset stalwart_password STALWART_PASSWORD STALWART_TOKEN STALWART_URL STALWART_USER
  if [[ -n ${ssh_control_socket} ]]; then
    ssh "${ssh_options[@]}" -S "${ssh_control_socket}" -O exit "${ssh_target}" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n ${ssh_control_dir} ]]; then
    rm -f -- "${ssh_control_socket}"
    rmdir -- "${ssh_control_dir}" >/dev/null 2>&1 || true
  fi
  if [[ -n ${tofu_plan} ]]; then
    rm -f -- "${tofu_plan}"
  fi
  if [[ -n ${runtime_password_secret} ]]; then
    if ! stalwart_podman secret rm "${runtime_password_secret}" >/dev/null 2>&1; then
      printf 'Failed to remove transient Podman secret %s; remove it manually.\n' \
        "${runtime_password_secret}" >&2
      status=1
    fi
  fi
  if [[ ${cleanup_deployment} == true ]]; then
    if make -C "${repo_root}" deploy; then
      production_restored=true
    else
      printf 'Failed to remove temporary Stalwart recovery access; run make deploy immediately.\n' >&2
      status=1
    fi
  fi
  if [[ ${remote_password_secret_created} == true ]]; then
    if [[ ${production_restored} != true ]]; then
      printf 'Temporary server-side Podman secret %s remains until production deploy succeeds.\n' \
        "${remote_password_secret}" >&2
      status=1
    elif ! ssh "${ssh_options[@]}" -o LogLevel=ERROR "${ssh_target}" \
      sudo podman secret rm "${remote_password_secret}" >/dev/null 2>&1; then
      printf 'Failed to remove temporary server-side Podman secret %s; remove it after make deploy succeeds.\n' \
        "${remote_password_secret}" >&2
      status=1
    fi
  fi
  if ((status != 0)); then
    printf 'Stalwart bootstrap failed during: %s.\n' "${bootstrap_stage}" >&2
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in curl date jq make openssl python3 ssh timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf '%s is required\n' "${command_name}" >&2
    exit 1
  }
done
command -v "${tofu_bin}" >/dev/null 2>&1 || {
  printf '%s is required\n' "${tofu_bin}" >&2
  exit 1
}

case ${tf_dir} in
  /*) tf_path=${tf_dir} ;;
  *) tf_path="${repo_root}/${tf_dir}" ;;
esac
case ${sops_infrastructure_file} in
  /*) sops_infrastructure_path=${sops_infrastructure_file} ;;
  *) sops_infrastructure_path="${repo_root}/${sops_infrastructure_file}" ;;
esac
case ${tf_vars} in
  /*) tf_vars_path=${tf_vars} ;;
  *) tf_vars_path="${tf_path}/${tf_vars}" ;;
esac

if [[ ! ${stalwart_hostname} =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  printf 'STALWART_HOSTNAME is not a valid DNS hostname.\n' >&2
  exit 2
fi
if [[ ! ${stalwart_domain} =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  printf 'STALWART_DOMAIN is not a valid DNS domain.\n' >&2
  exit 2
fi
for required_file in \
  "${compose_file}" \
  "${inventory_file}" \
  "${known_hosts_file}" \
  "${initial_plan}" \
  "${staging_plan}" \
  "${production_plan}" \
  "${mta_sts_plan}" \
  "${tf_path}/${authority_vars_name}" \
  "${tf_vars_path}" \
  "${sops_infrastructure_path}"; do
  if [[ ! -r ${required_file} ]]; then
    printf 'Required bootstrap input is missing: %s\n' "${required_file}" >&2
    exit 2
  fi
done

stalwart_require_local_podman

mapfile -t cli_images < <(
  sed -nE 's/^[[:space:]]*image:[[:space:]]*"(docker\.io\/stalwartlabs\/cli:[^"]+)"[[:space:]]*$/\1/p' \
    "${compose_file}"
)
if ((${#cli_images[@]} != 1)); then
  printf 'Expected exactly one pinned Stalwart CLI image in %s\n' "${compose_file}" >&2
  exit 1
fi
cli_image=${cli_images[0]}

IFS=$'\t' read -r ssh_host ssh_user < <(
  python3 - "${inventory_file}" "${stalwart_inventory_host}" <<'PY'
import sys

import yaml

inventory_path, host_name = sys.argv[1:]
with open(inventory_path, encoding="utf-8") as handle:
    inventory = yaml.safe_load(handle)

all_group = inventory["all"]
mail_hosts = all_group["children"]["fcos"]["children"]["mail"]["hosts"]
host = mail_hosts[host_name]
print(f'{host["ansible_host"]}\t{all_group["vars"]["ansible_user"]}')
PY
)
if [[ ! ${ssh_host} =~ ^[A-Za-z0-9:.%-]+$ ]] || [[ ! ${ssh_user} =~ ^[A-Za-z0-9_.-]+$ ]]; then
  printf 'Inventory returned an unsafe SSH endpoint.\n' >&2
  exit 2
fi

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts_file}"
)
ssh_target="${ssh_user}@${ssh_host}"

bootstrap_stage='authenticated SSH management channel'
ssh_control_dir=$(mktemp -d "${TMPDIR:-/tmp}/stalwart-ssh.XXXXXX")
chmod 0700 "${ssh_control_dir}"
ssh_control_socket="${ssh_control_dir}/control"
local_port=$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)
if [[ ! ${local_port} =~ ^[0-9]+$ ]] || \
  ((local_port < 1024 || local_port > 65535)); then
  printf 'Failed to allocate an ephemeral loopback port.\n' >&2
  exit 1
fi
ssh "${ssh_options[@]}" -fN \
  -M -S "${ssh_control_socket}" \
  -o ControlPersist=no \
  -o ExitOnForwardFailure=yes \
  -o LogLevel=ERROR \
  -L "127.0.0.1:${local_port}:127.0.0.1:8080" \
  "${ssh_target}"
ssh "${ssh_options[@]}" -S "${ssh_control_socket}" -O check "${ssh_target}" \
  >/dev/null

stalwart_password=$(openssl rand -hex 32)
if [[ ! ${stalwart_password} =~ ^[0-9a-f]{64}$ ]]; then
  printf 'OpenSSL did not generate the expected temporary recovery password.\n' >&2
  exit 1
fi
recovery_id=$(openssl rand -hex 16)
if [[ ! ${recovery_id} =~ ^[0-9a-f]{32}$ ]]; then
  printf 'OpenSSL did not generate the expected recovery-secret identifier.\n' >&2
  exit 1
fi
remote_password_secret="stalwart-bootstrap-recovery-${recovery_id}"

# An enrolled installation already has a hostname-valid TLS endpoint. Preserve
# that transport through the SSH-only bootstrap port. A first enrollment still
# needs Stalwart's loopback-only cleartext listener until its certificate and
# HTTPS listener have been declared.
bootstrap_stage='Stalwart bootstrap transport selection'
bootstrap_probe_status=$(ssh "${ssh_options[@]}" -o LogLevel=ERROR "${ssh_target}" \
  curl --insecure --silent --show-error --connect-timeout 3 --max-time 5 \
    --header=X-Forwarded-For:127.0.0.1 \
    --output=/dev/null --write-out=%{http_code} \
    'https://127.0.0.1:443/healthz/live' 2>/dev/null || true)
if [[ ${bootstrap_probe_status} =~ ^[1-5][0-9][0-9]$ ]]; then
  bootstrap_tls=true
fi
unset bootstrap_probe_status

# This script owns the temporary recovery-access lifecycle. Even a failed
# bootstrap attempts to converge the Quadlet back to production through EXIT.
bootstrap_stage='temporary Stalwart recovery credential creation'
cleanup_deployment=true
if ! printf '%s' "${stalwart_user}:${stalwart_password}" | \
  ssh "${ssh_options[@]}" -o LogLevel=ERROR "${ssh_target}" \
    sudo podman secret create "${remote_password_secret}" - >/dev/null; then
  printf 'Failed to create the temporary server-side Stalwart recovery secret.\n' >&2
  exit 1
fi
remote_password_secret_created=true

bootstrap_stage='temporary loopback deployment'
STALWART_BOOTSTRAP_SECRET_NAME=${remote_password_secret} \
  STALWART_BOOTSTRAP_TLS=${bootstrap_tls} \
  make -C "${repo_root}" deploy-bootstrap

runtime_password_secret_candidate="stalwart-bootstrap-password-${recovery_id}"
if ! printf '%s' "${stalwart_password}" | \
  stalwart_podman secret create "${runtime_password_secret_candidate}" - >/dev/null; then
  printf 'Failed to create the transient local-Podman password secret.\n' >&2
  exit 1
fi
runtime_password_secret=${runtime_password_secret_candidate}
unset runtime_password_secret_candidate

if [[ ${bootstrap_tls} == true ]]; then
  stalwart_url="https://${stalwart_hostname}:${local_port}"
else
  stalwart_url="http://127.0.0.1:${local_port}"
fi
readiness_status=000
for attempt in $(seq 1 150); do
  if ! ssh "${ssh_options[@]}" -S "${ssh_control_socket}" -O check "${ssh_target}" \
    >/dev/null 2>&1; then
    printf 'The authenticated Stalwart SSH control connection is no longer active.\n' >&2
    exit 1
  fi
  readiness_args=(--fail --silent --show-error --max-time 2)
  if [[ ${bootstrap_tls} == true ]]; then
    readiness_args+=(--resolve "${stalwart_hostname}:${local_port}:127.0.0.1")
  fi
  if readiness_status=$(curl "${readiness_args[@]}" \
    --output /dev/null --write-out '%{http_code}' \
    "${stalwart_url}/.well-known/jmap" 2>/dev/null); then
    break
  fi
  if ((attempt % 15 == 0)); then
    printf 'Waiting for the Stalwart management API (last HTTP status: %s, %s/150).\n' \
      "${readiness_status:-000}" "${attempt}"
  fi
  if ((attempt == 150)); then
    printf 'Timed out waiting for the Stalwart management API through the authenticated SSH channel.\n' >&2
    ssh "${ssh_options[@]}" -o LogLevel=ERROR "${ssh_target}" \
      sudo systemctl --no-pager --full status mail-stalwart.service >&2 || true
    ssh "${ssh_options[@]}" -o LogLevel=ERROR "${ssh_target}" \
      sudo journalctl -u mail-stalwart.service -n 80 --no-pager >&2 || true
    exit 1
  fi
  sleep 2
done
unset readiness_status

run_cli() {
  if ! ssh "${ssh_options[@]}" -S "${ssh_control_socket}" -O check "${ssh_target}" \
    >/dev/null 2>&1; then
    printf 'Refusing to send Stalwart credentials without the authenticated SSH control connection.\n' >&2
    return 1
  fi
  local -a container_args=(
    run
    --rm
    --interactive
    --read-only
    --network host
    --cap-drop=all
    --security-opt=no-new-privileges
    "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777"
    --env XDG_CACHE_HOME=/tmp/cache
  )
  if [[ ${bootstrap_tls} == true ]]; then
    container_args+=(--add-host "${stalwart_hostname}:127.0.0.1")
  fi
  container_args+=(
    --env "STALWART_URL=${stalwart_url}"
    --env "STALWART_USER=${stalwart_user}"
    --secret "${runtime_password_secret},type=env,target=STALWART_PASSWORD"
  )
  container_args+=("${cli_image}" --no-color "$@")
  stalwart_podman "${container_args[@]}"
}

capture_cli() {
  local output status
  if output=$(run_cli "$@"); then
    printf '%s\n' "${output}"
  else
    status=$?
    if [[ -n ${output} ]]; then
      printf 'Stalwart CLI error: %s\n' "${output}" >&2
    else
      printf 'Stalwart CLI exited with status %s and no diagnostic output.\n' "${status}" >&2
    fi
    return "${status}"
  fi
}

apply_plan() {
  local plan=$1 label=$2
  printf 'Validating %s.\n' "${label}"
  run_cli apply --stdin --dry-run <"${plan}"
  run_cli apply --stdin --json <"${plan}"
}

mta_sts_configuration_matches() {
  capture_cli get MtaSts --fields mode,maxAge,mxHosts --json |
    jq -e '
      .mode == "enforce"
      and .maxAge == 604800000
      and .mxHosts == {}
    ' >/dev/null
}

ensure_enforcing_mta_sts_configuration() {
  if mta_sts_configuration_matches; then
    printf 'Enforcing MTA-STS configuration: already in sync.\n'
    return
  fi
  apply_plan "${mta_sts_plan}" 'the enforcing MTA-STS policy plan'
  run_cli create Action/ReloadSettings >/dev/null
  printf 'Stalwart settings reload after MTA-STS update: requested.\n'
}

public_endpoint_reachable() {
  local address_family=$1
  curl --insecure --fail --silent --show-error \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 5 \
    --tlsv1.3 --tls-max 1.3 \
    --output /dev/null \
    "https://${stalwart_hostname}/"
}

wait_for_public_endpoints() {
  local attempt
  for attempt in $(seq 1 30); do
    if public_endpoint_reachable -4 >/dev/null 2>&1 && \
      public_endpoint_reachable -6 >/dev/null 2>&1; then
      return 0
    fi
    if ((attempt < 30)); then
      sleep 2
    fi
  done
  return 1
}

production_certificate_is_valid() {
  local address_family=$1 autoconfig_xml autodiscover_xml pacc_json
  curl --fail --silent \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    --output /dev/null \
    "https://${stalwart_hostname}/" && \
    curl --fail --silent \
      "${address_family}" \
      --connect-timeout 3 \
      --max-time 20 \
      --tlsv1.3 --tls-max 1.3 \
      --output /dev/null \
      "https://mta-sts.${stalwart_domain}/.well-known/mta-sts.txt" || return 1

  autoconfig_xml=$(curl --fail --silent \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    "https://${stalwart_autoconfig_hostname}/mail/config-v1.1.xml?emailaddress=postmaster%40${stalwart_domain}") || return 1
  grep -Fq '<clientConfig version="1.1">' <<<"${autoconfig_xml}" || return 1
  grep -Fq "<hostname>${stalwart_hostname}</hostname>" <<<"${autoconfig_xml}" || return 1

  autodiscover_xml=$(curl --fail --silent \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    --header 'Content-Type: application/xml' \
    --data-binary @- \
    "https://${stalwart_autodiscover_hostname}/autodiscover/autodiscover.xml" <<EOF
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006"><Request><EMailAddress>postmaster@${stalwart_domain}</EMailAddress><AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema></Request></Autodiscover>
EOF
  ) || return 1
  grep -Fq '<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">' \
    <<<"${autodiscover_xml}" || return 1
  grep -Fq "<Server>${stalwart_hostname}</Server>" <<<"${autodiscover_xml}" || return 1

  pacc_json=$(curl --fail --silent \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    "https://${stalwart_ua_autoconfig_hostname}/.well-known/user-agent-configuration.json") || return 1
  jq -e \
    --arg hostname "${stalwart_hostname}" \
    '.protocols.imap.host == $hostname and .protocols.smtp.host == $hostname' \
    <<<"${pacc_json}" >/dev/null
}

mta_sts_policy_is_enforcing() {
  local address_family=$1 policy
  policy=$(curl --fail --silent --show-error \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    "https://mta-sts.${stalwart_domain}/.well-known/mta-sts.txt") || return 1
  stalwart_mta_sts_policy_matches "${stalwart_hostname}" "${policy}"
}

wait_for_enforcing_mta_sts_policy() {
  local attempt
  for attempt in $(seq 1 30); do
    if mta_sts_policy_is_enforcing -4 && mta_sts_policy_is_enforcing -6; then
      printf 'Enforcing MTA-STS policy over IPv4 and IPv6: verified.\n'
      return 0
    fi
    if ((attempt < 30)); then
      sleep 2
    fi
  done
  printf 'Timed out waiting for the public enforcing MTA-STS policy.\n' >&2
  return 1
}

bootstrap_stage='public HTTPS preflight'
if ! wait_for_public_endpoints; then
  printf 'The public Stalwart TLS endpoint is not reachable over both IPv4 and IPv6; refusing to change DNS or ACME state.\n' >&2
  exit 1
fi

bootstrap_stage='Stalwart administrator authentication and identity query'
domain_ndjson=$(capture_cli query Domain --fields name,description --json)
domain_id=$(jq -er -s --arg domain "${stalwart_domain}" '
  [.[] | select(.name == $domain)]
  | if length == 1 then .[0].id else empty end
' <<<"${domain_ndjson}") || true
domain_description=$(jq -er -s --arg domain "${stalwart_domain}" '
  [.[] | select(.name == $domain)]
  | if length == 1 then (.[] | .description // "") else "" end
' <<<"${domain_ndjson}")
first_rollout=false
if [[ -z ${domain_id} || \
      ${domain_description} == "${bootstrap_pending_description}" ]]; then
  first_rollout=true
fi

dkim_ndjson=''
if [[ -n ${domain_id} ]]; then
  dkim_ndjson=$(capture_cli query DkimSignature --fields selector,domainId,stage --json)
fi
selector_count=$(jq -er -s --arg domain_id "${domain_id}" '
  [.[] | select(.domainId == $domain_id) | .selector] | unique | length
' <<<"${dkim_ndjson:-}")

if [[ ${first_rollout} == true ]]; then
  bootstrap_stage='initial Stalwart declaration'
  apply_plan "${initial_plan}" 'the initial Stalwart identity, DNS provider, ACME providers, DKIM keys, and local Web UI plan'
  domain_ndjson=$(capture_cli query Domain --fields name,description --json)
  domain_id=$(jq -er -s --arg domain "${stalwart_domain}" '
    [.[] | select(.name == $domain)]
    | if length == 1 then .[0].id else error("expected exactly one managed domain") end
  ' <<<"${domain_ndjson}")
  dkim_ndjson=$(capture_cli query DkimSignature --fields selector,domainId,stage --json)
elif ((selector_count < 2)); then
  printf 'The existing managed Domain has fewer than two DKIM selectors; refusing to reset its production certificate state.\n' >&2
  exit 1
fi

bootstrap_stage='enforcing MTA-STS declaration'
ensure_enforcing_mta_sts_configuration

authority_vars_file="${tf_path}/${authority_vars_name}"
approved_selectors_json=$(jq -ce '
  .stalwart_dkim_selectors
  | select(type == "array" and length >= 2)
  | if all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$"))
    then unique | sort
    else error("invalid approved DKIM selector set")
    end
' "${authority_vars_file}")
approved_production_account_uri=$(jq -er '
  .stalwart_acme_account_uri
  | select(type == "string")
  | select(test("^https://acme-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$"))
' "${authority_vars_file}")
approved_staging_account_uri=$(jq -er '
  .stalwart_staging_acme_account_uri
  | if . == null then ""
    elif type == "string"
      and test("^https://acme-staging-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$")
    then .
    else error("invalid approved staging ACME account URI")
    end
' "${authority_vars_file}")

live_dkim_json=$(jq -ce -s --arg domain_id "${domain_id}" '
  [
    .[]
    | select(.domainId == $domain_id)
    | {selector, stage}
  ]
  | if length >= 2
      and all(.[].selector; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$"))
      and all(.[].stage; . == "active" or . == "retiring")
    then sort_by(.selector)
    else error("expected only approved active or retiring DKIM selectors")
    end
' <<<"${dkim_ndjson}")
selectors_json=$(jq -ce '[.[].selector] | unique | sort' <<<"${live_dkim_json}")
if [[ ${selectors_json} != "${approved_selectors_json}" ]]; then
  printf 'Live DKIM selectors differ from reviewed %s; review and commit an explicit rotation before retrying.\n' \
    "${authority_vars_file}" >&2
  exit 1
fi

acme_provider_ndjson=$(capture_cli query AcmeProvider \
  --fields directory,accountUri --json)
staging_account_uri=''
if [[ ${first_rollout} == true ]]; then
  staging_account_uri=$(jq -er -s --arg directory "${staging_acme_directory}" '
    [.[] | select(.directory == $directory) | .accountUri]
    | if length == 1
        and (.[0] | type == "string")
        and (.[0] | test("^https://acme-staging-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$"))
      then .[0]
      else error("expected exactly one registered ACME staging account URI")
      end
  ' <<<"${acme_provider_ndjson}")
fi
production_account_uri=$(jq -er -s --arg directory "${production_acme_directory}" '
  [.[] | select(.directory == $directory) | .accountUri]
  | if length == 1
      and (.[0] | type == "string")
      and (.[0] | test("^https://acme-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$"))
    then .[0]
    else error("expected exactly one registered ACME production account URI")
    end
' <<<"${acme_provider_ndjson}")
if [[ ${production_account_uri} != "${approved_production_account_uri}" ]]; then
  printf 'Live production ACME identity differs from reviewed %s; use a separate reviewed rotation.\n' \
    "${authority_vars_file}" >&2
  exit 1
fi
if [[ ${first_rollout} == true ]]; then
  if [[ -z ${approved_staging_account_uri} || \
        ${staging_account_uri} != "${approved_staging_account_uri}" ]]; then
    printf 'First enrollment requires the exact staging ACME account URI to be reviewed in %s before CAA can change.\n' \
      "${authority_vars_file}" >&2
    exit 1
  fi
fi

desec_api_request() {
  local method=$1 api_path=$2 response_mode=${3:-body}
  if [[ ${method} != GET ]] || \
    [[ ${response_mode} != body && ${response_mode} != status ]]; then
    printf 'Unsupported deSEC API request mode.\n' >&2
    return 2
  fi
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" --allow DESEC_API_TOKEN -- \
    bash -o pipefail -c '
      headers=$(mktemp)
      body=$(mktemp)
      trap '\''rm -f -- "$headers" "$body"'\'' EXIT HUP INT TERM
      curl_args=(
        --silent --show-error --request "$1" --config -
        --dump-header "$headers" --output "$body" --write-out "%{http_code}"
      )
      # Polling callers provide the retry budget. Do not let curl hide a final
      # 429 and then have the outer loop retry before deSEC permits it.
      if ! http_status=$(
        printf "%s\n" "header = \"Authorization: Token ${DESEC_API_TOKEN}\"" |
          env -u DESEC_API_TOKEN curl "${curl_args[@]}" "$2"
      ); then
        exit 1
      fi
      if [[ $http_status == 429 ]]; then
        retry_after=$(awk '\''
          BEGIN { IGNORECASE = 1 }
          /^retry-after:/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/\r$/, "")
            print
            exit
          }
        '\'' "$headers")
        if [[ $retry_after =~ ^[0-9]+$ ]]; then
          printf "deSEC throttled this token; retry after %s seconds.\n" \
            "$retry_after" >&2
        else
          printf "deSEC throttled this token; retry only after the provider limit resets.\n" >&2
        fi
        exit 75
      fi
      if [[ $3 == status ]]; then
        printf "%s" "$http_status"
      elif [[ $http_status =~ ^2[0-9][0-9]$ ]]; then
        cat "$body"
      else
        printf "deSEC API request failed with HTTP %s: " "$http_status" >&2
        cat "$body" >&2
        exit 1
      fi
    ' bash "${method}" "https://desec.io/api/v1/${api_path}" "${response_mode}"
}

desec_rrset_from_zone() {
  local subname=$1 record_type=$2
  jq -cer --arg subname "${subname}" --arg record_type "${record_type}" '
    [.[] | select(.subname == $subname and .type == $record_type)]
    | if length == 1
      then .[0]
      else error("expected exactly one matching RRset")
      end
  '
}

apply_opentofu_dns_boundary() {
  if [[ -z ${STALWART_CAA_ACCOUNT_URI:-} ]]; then
    printf 'A reviewed ACME account URI is required for the CAA plan.\n' >&2
    return 1
  fi
  tofu_plan="${tf_path}/stalwart-bootstrap.tfplan"
  rm -f -- "${tofu_plan}"
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" \
    --allow HCLOUD_TOKEN DESEC_API_TOKEN SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE \
    --optional MINIO_USER MINIO_PASSWORD B2_APPLICATION_KEY_ID B2_APPLICATION_KEY -- \
    "${tofu_bin}" -chdir="${tf_path}" plan \
      -parallelism=1 \
      -var-file="${tf_vars_path}" \
      -var-file="${authority_vars_file}" \
      -var="stalwart_acme_account_uri=${STALWART_CAA_ACCOUNT_URI}" \
      -target=desec_token_policy.stalwart_mail_records \
      -target=desec_rrset.apex_caa \
      -target=desec_rrset.mail_caa \
      -target='desec_rrset.static_zone["user_agent_autoconfig_alias"]' \
      -out="${tofu_plan}"
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" \
    --allow HCLOUD_TOKEN DESEC_API_TOKEN SCW_ACCESS_KEY SCW_SECRET_KEY TOFU_STATE_PASSPHRASE \
    --optional MINIO_USER MINIO_PASSWORD B2_APPLICATION_KEY_ID B2_APPLICATION_KEY -- \
    "${tofu_bin}" -chdir="${tf_path}" apply "${tofu_plan}"
  if ! make -C "${repo_root}" \
      TOFU="${TOFU_BINARY:-tofu}" \
      TF_DIR="${tf_path}" \
      SOPS_INFRASTRUCTURE_FILE="${sops_infrastructure_path}" \
      tofu-state-snapshot; then
    printf '%s\n' \
      'OpenTofu changed remote state, but its encrypted local recovery snapshot failed.' \
      >&2
    return 1
  fi
  rm -f -- "${tofu_plan}"
  tofu_plan=''
}

select_acme_caa_account() {
  local account_uri=$1
  if [[ ${account_uri} != "${approved_production_account_uri}" && \
        ${account_uri} != "${approved_staging_account_uri}" ]]; then
    printf 'Refusing an ACME account that is absent from reviewed controller authority.\n' >&2
    return 1
  fi
  STALWART_CAA_ACCOUNT_URI=${account_uri} apply_opentofu_dns_boundary
}

bootstrap_stage='exact Stalwart mail-DNS and CAA deSEC policy'
if [[ ${first_rollout} != true ]]; then
  select_acme_caa_account "${production_account_uri}"
  # Reconcile the Domain after expanding its exact-name token permissions so
  # existing installations transfer all supported mail records atomically.
  bootstrap_stage='production Domain DNS-policy ownership handoff'
  apply_plan "${production_plan}" 'the production plan with native mail DNS publication and controller-owned CAA'
else
  select_acme_caa_account "${staging_account_uri}"
fi

matching_staging_certificate() {
  capture_cli query Certificate \
    --fields issuer,subjectAlternativeNames,notValidAfter \
    --json |
    jq -e -s \
      --arg hostname "${stalwart_hostname}" \
      --arg autoconfig "${stalwart_autoconfig_hostname}" \
      --arg autodiscover "${stalwart_autodiscover_hostname}" \
      --arg ua_autoconfig "${stalwart_ua_autoconfig_hostname}" '
      any(.[];
        .subjectAlternativeNames[$hostname] == true
        and .subjectAlternativeNames[$autoconfig] == true
        and .subjectAlternativeNames[$autodiscover] == true
        and .subjectAlternativeNames[$ua_autoconfig] == true
        and ((.issuer // "") | ascii_downcase | test("staging|fake le"))
      )
    ' >/dev/null
}

retire_staging_certificates() {
  local certificate_ndjson staging_ids
  certificate_ndjson=$(capture_cli query Certificate \
    --fields id,issuer,subjectAlternativeNames,notValidAfter \
    --json)
  staging_ids=$(jq -ce -s --arg hostname "${stalwart_hostname}" '
    [
      .[]
      | select(
          (.id | type == "string")
          and .subjectAlternativeNames[$hostname] == true
          and ((.issuer // "") | ascii_downcase | test("staging|fake le"))
        )
      | .id
    ]
    | unique
    | if length > 0 then . else error("expected at least one matching staging certificate") end
  ' <<<"${certificate_ndjson}")
  printf '%s\n' "${staging_ids}" | run_cli delete Certificate --stdin
}

retire_staging_acme_provider() {
  local provider_ndjson staging_ids
  provider_ndjson=$(capture_cli query AcmeProvider --fields id,directory --json)
  staging_ids=$(jq -ce -s --arg directory "${staging_acme_directory}" '
    [
      .[]
      | select(.directory == $directory and (.id | type == "string"))
      | .id
    ]
    | unique
  ' <<<"${provider_ndjson}")
  if [[ ${staging_ids} == '[]' ]]; then
    printf "Let's Encrypt staging ACME provider: already absent.\n"
    return
  fi
  printf '%s\n' "${staging_ids}" | run_cli delete AcmeProvider --stdin
  printf "Let's Encrypt staging ACME provider: retired.\n"
}

wait_for_staging_certificate() {
  local attempt
  for attempt in $(seq 1 60); do
    if matching_staging_certificate; then
      printf "Let's Encrypt staging certificate: verified.\n"
      return 0
    fi
    if ((attempt % 6 == 0)); then
      printf "Waiting for the Let's Encrypt staging certificate (%s/60).\n" "${attempt}"
    fi
    sleep 10
  done
  printf "Timed out waiting for the Let's Encrypt staging certificate. Recent tasks:\n" >&2
  run_cli query Task --json >&2 || true
  return 1
}

wait_for_production_certificate() {
  local attempt failure_reason
  # Stalwart processes each DNS-01 authorization sequentially and leaves the
  # task status as Pending while it is executing. With the full mail SAN set,
  # the configured five-minute per-name propagation timeout can legitimately
  # exceed ten minutes, so keep the recovery transport alive for up to one
  # hour. Timing out sooner would restart Stalwart during cleanup, interrupt
  # the worker, and leave its one-hour task lock behind.
  for attempt in $(seq 1 360); do
    if production_certificate_is_valid -4 && production_certificate_is_valid -6; then
      printf "Public Let's Encrypt production certificate: verified.\n"
      return 0
    fi
    if ((attempt % 3 == 0)) && \
      failure_reason=$(capture_cli query Task --fields status --json |
        jq -er -s --arg since "${production_refresh_started_at}" '
          [
            .[]
            | select(
                (."@type" == "DnsManagement" or ."@type" == "AcmeRenewal")
                and (.status.createdAt // "") >= $since
                and .status."@type" == "Failed"
              )
            | .status.failureReason
          ]
          | if length > 0 then join("; ") else empty end
        '); then
      printf 'The current Stalwart DNS/ACME task failed: %s\n' \
        "${failure_reason}" >&2
      return 1
    fi
    if ((attempt % 30 == 0)); then
      printf 'Waiting for the trusted production certificate (%s/360).\n' "${attempt}"
    fi
    sleep 10
  done
  printf 'Timed out waiting for a hostname-valid production certificate. Recent tasks:\n' >&2
  run_cli query Task --json >&2 || true
  return 1
}

smtp_spki_sha256() {
  local address_family=$1
  timeout 20 openssl s_client \
    "${address_family}" \
    -starttls smtp \
    -connect "${stalwart_hostname}:25" \
    -servername "${stalwart_hostname}" \
    -verify_hostname "${stalwart_hostname}" \
    -verify_return_error \
    -showcerts </dev/null 2>/dev/null | \
    openssl x509 -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | \
    openssl dgst -sha256 -hex 2>/dev/null | \
    awk '{print toupper($NF)}'
}

authenticated_tlsa_records() {
  local request_status rrset tlsa_subname
  tlsa_subname="_25._tcp.${stalwart_hostname%."${stalwart_domain}"}"
  rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/${tlsa_subname}/TLSA/") || {
    request_status=$?
    return "${request_status}"
  }
  jq -er --arg subname "${tlsa_subname}" '
    select(
      .subname == $subname
      and .type == "TLSA"
      and (.records | type == "array" and length > 0)
    )
    | .records[]
  ' <<<"${rrset}"
}

tlsa_matches_live_certificate() {
  local ipv4_spki ipv6_spki records request_status
  ipv4_spki=$(smtp_spki_sha256 -4) || return 1
  ipv6_spki=$(smtp_spki_sha256 -6) || return 1
  if [[ ! ${ipv4_spki} =~ ^[0-9A-F]{64}$ || ${ipv4_spki} != "${ipv6_spki}" ]]; then
    return 1
  fi
  records=$(authenticated_tlsa_records) || {
    request_status=$?
    return "${request_status}"
  }
  awk -v expected="${ipv4_spki}" '
    $1 == 3 && $2 == 1 && $3 == 1 {
      digest = ""
      for (field = 4; field <= NF; field++) {
        digest = digest $field
      }
      if (toupper(digest) == expected) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<<"${records}"
}

wait_for_dane_tlsa() {
  local attempt request_status
  for attempt in $(seq 1 36); do
    if tlsa_matches_live_certificate; then
      printf 'Authenticated deSEC DANE TLSA matches the Web-PKI-verified IPv4 and IPv6 SMTP certificate: verified.\n'
      return 0
    else
      request_status=$?
      if ((request_status == 75)); then
        return "${request_status}"
      fi
    fi
    if ((attempt % 6 == 0)); then
      printf 'Waiting for authenticated deSEC DANE TLSA publication (%s/36).\n' "${attempt}"
    fi
    sleep 10
  done
  return 1
}

schedule_dns_reconciliation() {
  local dns_refresh_due renew_certificate=$1
  if [[ ${renew_certificate} != true && ${renew_certificate} != false ]]; then
    printf 'DNS reconciliation requires an explicit certificate-renewal decision.\n' >&2
    return 2
  fi
  dns_refresh_due=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  jq -cn \
    --arg domain_id "${domain_id}" \
    --arg due "${dns_refresh_due}" \
    --argjson renew_certificate "${renew_certificate}" \
    '{
      domainId: $domain_id,
      updateRecords: {
        dkim: true,
        tlsa: true,
        spf: true,
        mx: true,
        dmarc: true,
        srv: true,
        mtaSts: true,
        tlsRpt: true,
        autoConfig: true,
        autoConfigLegacy: true,
        autoDiscover: true
      },
      onSuccessRenewCertificate: $renew_certificate,
      status: {"@type": "Pending", due: $due}
    }' |
    run_cli create Task/DnsManagement --stdin >/dev/null
}

refresh_production_dns_and_dane() {
  local refresh_attempt wait_status
  for refresh_attempt in 1 2 3; do
    bootstrap_stage="Let's Encrypt production issuance and DNS refresh ${refresh_attempt}/3"
    production_refresh_started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    apply_plan "${production_plan}" 'the production DNS-01 certificate plan'

    # A manual-to-automatic transition schedules the initial publication for a
    # first enrollment. Existing automatic Domains require an explicit task to
    # retry a failed publication; reapplying an unchanged Domain is not a retry.
    if [[ ${first_rollout} != true || ${refresh_attempt} -gt 1 ]]; then
      schedule_dns_reconciliation true
      printf 'Stalwart DNS reconciliation and chained ACME renewal: scheduled.\n'
    fi
    wait_for_production_certificate

    bootstrap_stage="authenticated deSEC DANE TLSA publication ${refresh_attempt}/3"
    if wait_for_dane_tlsa; then
      return 0
    else
      wait_status=$?
      if ((wait_status == 75)); then
        return "${wait_status}"
      fi
    fi
    if ((refresh_attempt < 3)); then
      printf 'The authenticated SMTP TLSA did not match after DNS refresh attempt %s/3; retrying the managed transition.\n' \
        "${refresh_attempt}" >&2
    fi
  done

  printf 'Timed out waiting for the authenticated DANE TLSA record to match the verified SMTP certificate. Recent tasks:\n' >&2
  run_cli query Task --json >&2 || true
  return 1
}

if [[ ${first_rollout} == true ]]; then
  bootstrap_stage="Let's Encrypt staging issuance"
  apply_plan "${staging_plan}" 'the staging DNS-01 certificate plan'
  wait_for_staging_certificate

  bootstrap_stage="Let's Encrypt staging certificate retirement"
  apply_plan "${initial_plan}" 'the temporary manual certificate transition plan'
  retire_staging_certificates

  bootstrap_stage="Let's Encrypt production account-bound CAA policy"
  select_acme_caa_account "${production_account_uri}"
fi

dane_status=1
if production_certificate_is_valid -4 && production_certificate_is_valid -6; then
  if tlsa_matches_live_certificate; then
    dane_status=0
  else
    dane_status=$?
    if ((dane_status == 75)); then
      exit "${dane_status}"
    fi
  fi
fi
if ((dane_status == 0)); then
  printf 'Production certificate and authenticated DANE TLSA already match: verified.\n'
else
  refresh_production_dns_and_dane
fi

bootstrap_stage="Let's Encrypt staging ACME provider retirement"
retire_staging_acme_provider

bootstrap_stage='public enforcing MTA-STS policy audit'
wait_for_enforcing_mta_sts_policy

# Reapplying an unchanged automatic Domain does not retry a stale or previously
# failed DNS publication. Always request one final idempotent reconciliation so
# the authoritative records reflect the declared report address and service set
# before the exact-state audit below. The already-verified certificate does not
# need to be renewed for this repair.
bootstrap_stage='final Stalwart mail DNS reconciliation'
mail_dns_refresh_started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
schedule_dns_reconciliation false
printf 'Final Stalwart mail DNS reconciliation: scheduled.\n'

mail_policy_matches() {
  local apex_mx_rrset apex_rrset apex_spf_rrset autoconfig_rrset
  local autodiscover_rrset caldav_rrset carddav_rrset dmarc_rrset
  local imaps_rrset jmap_rrset mail_rrset mail_spf_rrset
  local mta_sts_rrset submissions_rrset tls_reporting_rrset
  local request_status user_agent_autoconfig_rrset zone_rrsets
  zone_rrsets=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/") || {
    request_status=$?
    return "${request_status}"
  }
  apex_rrset=$(desec_rrset_from_zone '' CAA <<<"${zone_rrsets}") || return 1
  mail_rrset=$(desec_rrset_from_zone mail CAA <<<"${zone_rrsets}") || return 1
  apex_mx_rrset=$(desec_rrset_from_zone '' MX <<<"${zone_rrsets}") || return 1
  apex_spf_rrset=$(desec_rrset_from_zone '' TXT <<<"${zone_rrsets}") || return 1
  mail_spf_rrset=$(desec_rrset_from_zone mail TXT <<<"${zone_rrsets}") || return 1
  mta_sts_rrset=$(desec_rrset_from_zone mta-sts CNAME \
    <<<"${zone_rrsets}") || return 1
  dmarc_rrset=$(desec_rrset_from_zone _dmarc TXT <<<"${zone_rrsets}") || return 1
  tls_reporting_rrset=$(desec_rrset_from_zone _smtp._tls TXT \
    <<<"${zone_rrsets}") || return 1
  autoconfig_rrset=$(desec_rrset_from_zone autoconfig CNAME \
    <<<"${zone_rrsets}") || return 1
  autodiscover_rrset=$(desec_rrset_from_zone autodiscover CNAME \
    <<<"${zone_rrsets}") || return 1
  user_agent_autoconfig_rrset=$(desec_rrset_from_zone ua-auto-config CNAME \
    <<<"${zone_rrsets}") || return 1
  jmap_rrset=$(desec_rrset_from_zone _jmap._tcp SRV <<<"${zone_rrsets}") || return 1
  caldav_rrset=$(desec_rrset_from_zone _caldavs._tcp SRV \
    <<<"${zone_rrsets}") || return 1
  carddav_rrset=$(desec_rrset_from_zone _carddavs._tcp SRV \
    <<<"${zone_rrsets}") || return 1
  imaps_rrset=$(desec_rrset_from_zone _imaps._tcp SRV \
    <<<"${zone_rrsets}") || return 1
  submissions_rrset=$(desec_rrset_from_zone _submissions._tcp SRV \
    <<<"${zone_rrsets}") || return 1
  jq -e '
    .subname == ""
    and .type == "CAA"
    and (.records | sort) == ([
      "0 iodef \"mailto:caa@thefutureisprivate.dev\"",
      "128 issue \";\"",
      "128 issuemail \";\"",
      "128 issuevmc \";\"",
      "128 issuewild \";\""
    ] | sort)
  ' <<<"${apex_rrset}" >/dev/null || return 1

  jq -e \
    --arg account_uri "${production_account_uri}" '
      .subname == "mail"
      and .type == "CAA"
      and (.records | sort) == ([
        "0 iodef \"mailto:caa@thefutureisprivate.dev\"",
        "0 issuemail \";\"",
        "0 issuevmc \";\"",
        "128 issuewild \";\"",
        ("128 issue \"letsencrypt.org; accounturi=" + $account_uri
          + "; validationmethods=dns-01\"")
      ] | sort)
  ' <<<"${mail_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == ""
    and .type == "MX"
    and .records == [("10 " + $target)]
  ' <<<"${apex_mx_rrset}" >/dev/null || return 1

  jq -e '
    .subname == ""
    and .type == "TXT"
    and .records == ["\"v=spf1 mx -all\""]
  ' <<<"${apex_spf_rrset}" >/dev/null || return 1

  jq -e '
    .subname == "mail"
    and .type == "TXT"
    and .records == ["\"v=spf1 a -all\""]
  ' <<<"${mail_spf_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "mta-sts"
    and .type == "CNAME"
    and .records == [$target]
  ' <<<"${mta_sts_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "autoconfig"
    and .type == "CNAME"
    and .records == [$target]
  ' <<<"${autoconfig_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "autodiscover"
    and .type == "CNAME"
    and .records == [$target]
  ' <<<"${autodiscover_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "ua-auto-config"
    and .type == "CNAME"
    and .records == [$target]
  ' <<<"${user_agent_autoconfig_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "_jmap._tcp"
    and .type == "SRV"
    and .records == [("0 1 443 " + $target)]
  ' <<<"${jmap_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "_caldavs._tcp"
    and .type == "SRV"
    and .records == [("0 1 443 " + $target)]
  ' <<<"${caldav_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "_carddavs._tcp"
    and .type == "SRV"
    and .records == [("0 1 443 " + $target)]
  ' <<<"${carddav_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "_imaps._tcp"
    and .type == "SRV"
    and .records == [("0 1 993 " + $target)]
  ' <<<"${imaps_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "_submissions._tcp"
    and .type == "SRV"
    and .records == [("0 1 465 " + $target)]
  ' <<<"${submissions_rrset}" >/dev/null || return 1

  jq -e '
    .subname == "_dmarc"
    and .type == "TXT"
    and .records == ["\"v=DMARC1; p=reject; rua=mailto:reports@thefutureisprivate.dev\""]
  ' <<<"${dmarc_rrset}" >/dev/null || return 1

  jq -e '
    .subname == "_smtp._tls"
    and .type == "TXT"
    and .records == ["\"v=TLSRPTv1; rua=mailto:reports@thefutureisprivate.dev\""]
  ' <<<"${tls_reporting_rrset}" >/dev/null
}

wait_for_mail_policy() {
  local attempt failure_reason request_status
  for attempt in $(seq 1 60); do
    if mail_policy_matches; then
      printf 'Published CAA boundary and Stalwart mail DNS: verified.\n'
      return 0
    else
      request_status=$?
      if ((request_status == 75)); then
        return "${request_status}"
      fi
    fi
    if ((attempt % 4 == 0)) && \
      failure_reason=$(capture_cli query Task --fields status --json |
        jq -er -s --arg since "${mail_dns_refresh_started_at}" '
          [
            .[]
            | select(
                ."@type" == "DnsManagement"
                and (.status.createdAt // "") >= $since
                and .status."@type" == "Failed"
              )
            | .status.failureReason
          ]
          | if length > 0 then join("; ") else empty end
        '); then
      printf 'The final Stalwart DNS reconciliation failed: %s\n' \
        "${failure_reason}" >&2
      return 1
    fi
    if ((attempt % 4 == 0)); then
      printf 'Waiting for deSEC to publish the exact mail policy (%s/60).\n' \
        "${attempt}"
    fi
    if ((attempt < 60)); then
      sleep 15
    fi
  done
  printf 'Timed out waiting for deSEC to publish the exact mail DNS state.\n' >&2
  return 1
}

bootstrap_stage='deSEC CAA and reporting publication audit'
wait_for_mail_policy

bootstrap_stage='production ACME provider audit'
if ! acme_provider_ndjson=$(capture_cli query AcmeProvider \
  --fields directory,accountUri,challengeType,contact \
  --json); then
  printf 'Unable to read the production AcmeProvider for its final audit.\n' >&2
  exit 1
fi
if ! jq -e -s \
  --arg account_uri "${production_account_uri}" \
  --arg contact "contact@${stalwart_domain}" '
    any(.[];
      .directory == "https://acme-v02.api.letsencrypt.org/directory"
      and .challengeType == "Dns01"
      and .accountUri == $account_uri
      and .contact == {($contact): true}
    )
    and all(.[];
      .directory != "https://acme-staging-v02.api.letsencrypt.org/directory"
    )
  ' <<<"${acme_provider_ndjson}" >/dev/null; then
  printf 'Production AcmeProvider audit failed; observed managed fields:\n' >&2
  jq -c -s 'map({directory, accountUri, challengeType, contact})' \
    <<<"${acme_provider_ndjson}" >&2
  exit 1
fi
printf 'Production ACME provider configuration: verified.\n'

bootstrap_stage='production Domain certificate and DNS policy audit'
if ! domain_ndjson=$(capture_cli query Domain \
  --fields name,certificateManagement,dkimManagement,dnsManagement,reportAddressUri \
  --json); then
  printf 'Unable to read the production Domain for its final audit.\n' >&2
  exit 1
fi
if ! jq -e -s --arg domain "${stalwart_domain}" '
    any(.[];
      .name == $domain
      and .certificateManagement."@type" == "Automatic"
      and .certificateManagement.subjectAlternativeNames == {
        "autoconfig": true,
        "autodiscover": true,
        "mail": true,
        "mta-sts": true,
        "ua-auto-config": true
      }
      and .dkimManagement."@type" == "Automatic"
      and .dnsManagement."@type" == "Automatic"
      and .dnsManagement.origin == $domain
      and (.dnsManagement.publishRecords.caa // false) == false
      and .dnsManagement.publishRecords.dmarc == true
      and .dnsManagement.publishRecords.tlsRpt == true
      and .dnsManagement.publishRecords.autoConfigLegacy == true
      and .dnsManagement.publishRecords.autoDiscover == true
      and .dnsManagement.publishRecords.dkim == true
      and .dnsManagement.publishRecords.mx == true
      and .dnsManagement.publishRecords.spf == true
      and .dnsManagement.publishRecords.srv == true
      and .dnsManagement.publishRecords.tlsa == true
      and .reportAddressUri == "mailto:reports@thefutureisprivate.dev"
    )
  ' <<<"${domain_ndjson}" >/dev/null; then
  printf 'Production Domain audit failed; observed managed fields:\n' >&2
  jq -c -s --arg domain "${stalwart_domain}" '
    [
      .[]
      | select(.name == $domain)
      | {
          name,
          certificateManagementType: .certificateManagement."@type",
          subjectAlternativeNames: .certificateManagement.subjectAlternativeNames,
          dkimManagementType: .dkimManagement."@type",
          dnsManagementType: .dnsManagement."@type",
          dnsOrigin: .dnsManagement.origin,
          publishRecords: .dnsManagement.publishRecords,
          reportAddressUri
        }
    ]
  ' <<<"${domain_ndjson}" >&2
  exit 1
fi
printf 'Production Domain certificate and DNS policy: verified.\n'

bootstrap_stage='production MTA-STS object audit'
if ! mta_sts_json=$(capture_cli get MtaSts \
  --fields mode,maxAge,mxHosts --json); then
  printf 'Unable to read the MtaSts object for its final audit.\n' >&2
  exit 1
fi
if ! jq -e '
    .mode == "enforce"
    and .maxAge == 604800000
    and .mxHosts == {}
  ' <<<"${mta_sts_json}" >/dev/null; then
  printf 'MtaSts object audit failed; observed managed fields:\n' >&2
  jq -c '{mode, maxAge, mxHosts}' <<<"${mta_sts_json}" >&2
  exit 1
fi
printf 'Production MTA-STS object configuration: verified.\n'

bootstrap_stage='permanent administrator handoff'
account_ndjson=$(capture_cli query Account --fields emailAddress,roles --json)
if jq -e -s 'any(.[]; .roles."@type" == "Admin")' <<<"${account_ndjson}" >/dev/null; then
  printf 'Existing permanent administrator: verified.\n'
else
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'A terminal is required to provision and verify a permanent administrator through the Web UI.\n' >&2
    exit 1
  fi
  printf '\nTemporary recovery administrator: %s\nTemporary recovery password: %s\n\n' \
    "${stalwart_user}" "${stalwart_password}" >/dev/tty
  printf 'Open https://%s/admin, create or repair a regular administrator account,\n' \
    "${stalwart_hostname}" >/dev/tty
  printf 'then sign out and back in with that regular account before continuing.\n' >/dev/tty
  while true; do
    read -r -p 'Press Enter after the permanent administrator login works: ' </dev/tty
    account_ndjson=$(capture_cli query Account --fields emailAddress,roles --json)
    if jq -e -s 'any(.[]; .roles."@type" == "Admin")' <<<"${account_ndjson}" >/dev/null; then
      break
    fi
    printf 'No regular account with the built-in Admin role exists yet; finish that Web UI step first.\n' \
      >/dev/tty
  done
fi

printf 'Stalwart DNS, DKIM, OpenTofu-owned CAA/reporting, and production ACME configuration: verified.\n'
