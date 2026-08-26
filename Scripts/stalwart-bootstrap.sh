#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
compose_file="${repo_root}/Ansible/compose.yaml"
inventory_file=${ANSIBLE_INVENTORY:-"${repo_root}/Ansible/inventory/hosts.yml"}
known_hosts_file=${ANSIBLE_KNOWN_HOSTS:-"${repo_root}/Ansible/inventory/known_hosts"}
initial_plan="${repo_root}/Stalwart/bootstrap-initial.ndjson"
staging_plan="${repo_root}/Stalwart/bootstrap-staging.ndjson"
production_plan="${repo_root}/Stalwart/bootstrap-production.ndjson"
production_dns_refresh_plan="${repo_root}/Stalwart/bootstrap-production-dns-refresh.ndjson"
mta_sts_plan="${repo_root}/Stalwart/mta-sts.ndjson"
tf_dir=${TF_DIR:-OpenTofu}
tf_vars=${TF_VARS:-terraform.tfvars}
tofu_bin=${TOFU:-tofu}
sops_infrastructure_file=${SOPS_INFRASTRUCTURE_FILE:-SOPS/infrastructure.sops.yaml}
generated_vars_name=${STALWART_DKIM_VARS:-stalwart-dkim.generated.tfvars.json}
stalwart_domain=thefutureisprivate.dev
stalwart_hostname=mail.thefutureisprivate.dev
staging_acme_directory=https://acme-staging-v02.api.letsencrypt.org/directory
production_acme_directory=https://acme-v02.api.letsencrypt.org/directory
stalwart_inventory_host=${STALWART_INVENTORY_HOST:-mail-01}
stalwart_user='admin'
stalwart_password=''
unset STALWART_PASSWORD STALWART_USER
local_port=${STALWART_BOOTSTRAP_LOCAL_PORT:-18080}
runtime=${STALWART_CLI_RUNTIME:-}
tunnel_pid=''
cleanup_deployment=false
tofu_plan=''
runtime_password_secret=''
remote_password_secret=''
remote_password_secret_created=false
bootstrap_stage='local preflight'
ssh_options=()
ssh_target=''

if (($# != 0)); then
  printf 'Usage: %s\n' "${0##*/}" >&2
  exit 2
fi

cleanup() {
  local status=$?
  local production_restored=false
  trap - EXIT HUP INT TERM
  unset stalwart_password STALWART_PASSWORD STALWART_TOKEN STALWART_URL STALWART_USER
  if [[ -n ${tunnel_pid} ]]; then
    kill "${tunnel_pid}" >/dev/null 2>&1 || true
    wait "${tunnel_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n ${tofu_plan} ]]; then
    rm -f -- "${tofu_plan}"
  fi
  if [[ -n ${runtime_password_secret} ]]; then
    if ! container_engine podman secret rm "${runtime_password_secret}" >/dev/null 2>&1; then
      printf 'Failed to remove transient Podman secret %s; remove it manually.\n' \
        "${runtime_password_secret}" >&2
      status=1
    fi
  fi
  if [[ ${cleanup_deployment} == true ]]; then
    if make -C "${repo_root}" deploy; then
      production_restored=true
    else
      printf 'Failed to remove the loopback bootstrap listener; run make deploy immediately.\n' >&2
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

for command_name in curl dig jq make openssl python3 ssh timeout; do
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

if [[ ! ${local_port} =~ ^[0-9]+$ ]] || ((local_port < 1024 || local_port > 65535)); then
  printf 'STALWART_BOOTSTRAP_LOCAL_PORT must be between 1024 and 65535.\n' >&2
  exit 2
fi
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
  "${production_dns_refresh_plan}" \
  "${mta_sts_plan}" \
  "${tf_vars_path}" \
  "${sops_infrastructure_path}"; do
  if [[ ! -r ${required_file} ]]; then
    printf 'Required bootstrap input is missing: %s\n' "${required_file}" >&2
    exit 2
  fi
done

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

# This script owns the temporary listener lifecycle. Even a failed bootstrap
# attempts to converge the Quadlet back to its production form through EXIT.
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
  make -C "${repo_root}" deploy-bootstrap

if [[ ${runtime} == podman && -n ${CONTAINER_ID:-} ]] && \
  command -v distrobox-host-exec >/dev/null 2>&1; then
  runtime_password_secret_candidate="stalwart-bootstrap-password-${recovery_id}"
  if ! printf '%s' "${stalwart_password}" | \
    container_engine podman secret create "${runtime_password_secret_candidate}" - >/dev/null; then
    printf 'Failed to create the transient host-Podman password secret.\n' >&2
    exit 1
  fi
  runtime_password_secret=${runtime_password_secret_candidate}
  unset runtime_password_secret_candidate
fi

bootstrap_stage='SSH management tunnel'
ssh "${ssh_options[@]}" -N \
  -o ExitOnForwardFailure=yes \
  -o LogLevel=QUIET \
  -L "127.0.0.1:${local_port}:127.0.0.1:8080" \
  "${ssh_target}" &
tunnel_pid=$!

stalwart_url="http://127.0.0.1:${local_port}"
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 2 \
    "${stalwart_url}/.well-known/jmap" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${tunnel_pid}" >/dev/null 2>&1; then
    wait "${tunnel_pid}" || true
    printf 'The Stalwart SSH tunnel exited before the management API became ready.\n' >&2
    exit 1
  fi
  if ((attempt == 30)); then
    printf 'Timed out waiting for the loopback Stalwart management API.\n' >&2
    exit 1
  fi
  sleep 1
done

run_cli() {
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
  if [[ -n ${runtime_password_secret} ]]; then
    container_args+=(
      --env "STALWART_URL=${stalwart_url}"
      --env "STALWART_USER=${stalwart_user}"
      --secret "${runtime_password_secret},type=env,target=STALWART_PASSWORD"
    )
  else
    container_args+=(--env STALWART_URL --env STALWART_USER --env STALWART_PASSWORD)
  fi
  container_args+=("${cli_image}" --no-color "$@")

  if [[ -n ${runtime_password_secret} ]]; then
    container_engine "${runtime}" "${container_args[@]}"
  else
    STALWART_URL=${stalwart_url} \
      STALWART_USER=${stalwart_user} \
      STALWART_PASSWORD=${stalwart_password} \
      container_engine "${runtime}" "${container_args[@]}"
  fi
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
  local address_family=$1
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
      "https://mta-sts.${stalwart_domain}/.well-known/mta-sts.txt"
}

mta_sts_policy_is_enforcing() {
  local address_family=$1 policy
  policy=$(curl --fail --silent --show-error \
    "${address_family}" \
    --connect-timeout 3 \
    --max-time 20 \
    --tlsv1.3 --tls-max 1.3 \
    "https://mta-sts.${stalwart_domain}/.well-known/mta-sts.txt") || return 1
  awk -v expected_mx="mx: ${stalwart_hostname}" '
    { sub(/\r$/, "") }
    $0 == "version: STSv1" { version++ }
    $0 == "mode: enforce" { mode++ }
    $0 == "max_age: 604800" { max_age++ }
    $0 == expected_mx { mx++ }
    END { exit(version == 1 && mode == 1 && max_age == 1 && mx == 1 ? 0 : 1) }
  ' <<<"${policy}"
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
domain_ndjson=$(capture_cli query Domain --fields name --json)
domain_id=$(jq -er -s --arg domain "${stalwart_domain}" '
  [.[] | select(.name == $domain)]
  | if length == 1 then .[0].id else empty end
' <<<"${domain_ndjson}") || true
first_rollout=false
if [[ -z ${domain_id} ]]; then
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
  domain_ndjson=$(capture_cli query Domain --fields name --json)
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

selectors_json=$(jq -ce -s --arg domain_id "${domain_id}" '
  [
    .[]
    | select(.domainId == $domain_id)
    | .selector
    | select(test("^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$"))
  ]
  | unique
  | sort
  | if length >= 2 then . else error("expected at least two valid DKIM selectors") end
' <<<"${dkim_ndjson}")

generated_vars_file="${tf_path}/${generated_vars_name}"
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
      else error("expected exactly one registered Let’s Encrypt staging account URI")
      end
  ' <<<"${acme_provider_ndjson}")
fi
production_account_uri=$(jq -er -s --arg directory "${production_acme_directory}" '
  [.[] | select(.directory == $directory) | .accountUri]
  | if length == 1
      and (.[0] | type == "string")
      and (.[0] | test("^https://acme-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$"))
    then .[0]
    else error("expected exactly one registered Let’s Encrypt production account URI")
    end
' <<<"${acme_provider_ndjson}")

write_generated_vars() {
  local account_uri=$1 generated_vars_tmp
  generated_vars_tmp=$(mktemp "${generated_vars_file}.XXXXXX")
  if ! jq -n \
    --argjson selectors "${selectors_json}" \
    --arg account_uri "${account_uri}" \
    '{
      stalwart_dkim_selectors: $selectors,
      stalwart_acme_account_uri: $account_uri
    }' >"${generated_vars_tmp}"; then
    rm -f -- "${generated_vars_tmp}"
    return 1
  fi
  chmod 0600 "${generated_vars_tmp}"
  mv -f -- "${generated_vars_tmp}" "${generated_vars_file}"
  printf 'Wrote exact DKIM selectors and ACME account URI to %s.\n' \
    "${generated_vars_file}"
}

desec_api_request() {
  local method=$1 api_path=$2 response_mode=${3:-body}
  if [[ ${method} != GET && ${method} != DELETE ]] || \
    [[ ${response_mode} != body && ${response_mode} != status ]]; then
    printf 'Unsupported deSEC API request mode.\n' >&2
    return 2
  fi
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" --allow DESEC_API_TOKEN -- \
    bash -o pipefail -c '
      curl_args=(--silent --show-error --request "$1" --config -)
      if [[ $3 == status ]]; then
        curl_args+=(--output /dev/null --write-out "%{http_code}")
      else
        curl_args+=(--fail)
      fi
      printf "%s\n" "header = \"Authorization: Token ${DESEC_API_TOKEN}\"" |
        env -u DESEC_API_TOKEN curl "${curl_args[@]}" "$2"
    ' bash "${method}" "https://desec.io/api/v1/${api_path}" "${response_mode}"
}

apply_opentofu_dns_boundary() {
  tofu_plan="${tf_path}/stalwart-bootstrap.tfplan"
  rm -f -- "${tofu_plan}"
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" --allow HCLOUD_TOKEN DESEC_API_TOKEN -- \
    "${tofu_bin}" -chdir="${tf_path}" plan \
      -var-file="${tf_vars_path}" \
      -var-file="${generated_vars_file}" \
      -target=desec_token_policy.stalwart_mail_records \
      -target=desec_rrset.apex_caa \
      -target=desec_rrset.mail_caa \
      -target='desec_rrset.imported_zone["dmarc"]' \
      -target='desec_rrset.imported_zone["tls_reporting"]' \
      -out="${tofu_plan}"
  SOPS_SECRETS_FILE="${sops_infrastructure_path}" \
    "${repo_root}/SOPS/exec-env.sh" --allow HCLOUD_TOKEN DESEC_API_TOKEN -- \
    "${tofu_bin}" -chdir="${tf_path}" apply "${tofu_plan}"
  rm -f -- "${tofu_plan}"
  tofu_plan=''
}

select_acme_caa_account() {
  local account_uri=$1
  write_generated_vars "${account_uri}"
  apply_opentofu_dns_boundary
}

bootstrap_stage='legacy autoconfiguration DNS retirement'
desec_api_request DELETE \
  "domains/${stalwart_domain}/rrsets/autoconfig/CNAME/"

bootstrap_stage='exact DKIM, CAA, and reporting deSEC policy'
if [[ ${first_rollout} != true ]]; then
  select_acme_caa_account "${production_account_uri}"
  # Existing installations previously let Stalwart publish CAA, DMARC, and
  # TLS-RPT. Reconcile the Domain so future DNS tasks leave every
  # OpenTofu-owned policy RRset alone, then reassert their desired content.
  bootstrap_stage='production Domain DNS-policy ownership handoff'
  apply_plan "${production_plan}" 'the production plan without native CAA, DMARC, or TLS-RPT publication'
  bootstrap_stage='OpenTofu DNS-policy ownership reassertion'
  select_acme_caa_account "${production_account_uri}"
else
  select_acme_caa_account "${staging_account_uri}"
fi

matching_staging_certificate() {
  capture_cli query Certificate \
    --fields issuer,subjectAlternativeNames,notValidAfter \
    --json |
    jq -e -s --arg hostname "${stalwart_hostname}" '
      any(.[];
        .subjectAlternativeNames[$hostname] == true
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
  local attempt
  for attempt in $(seq 1 60); do
    if production_certificate_is_valid -4 && production_certificate_is_valid -6; then
      printf "Public Let's Encrypt production certificate: verified.\n"
      return 0
    fi
    if ((attempt % 6 == 0)); then
      printf 'Waiting for the trusted production certificate (%s/60).\n' "${attempt}"
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
    -showcerts </dev/null 2>/dev/null | \
    openssl x509 -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | \
    openssl dgst -sha256 -hex 2>/dev/null | \
    awk '{print toupper($NF)}'
}

authoritative_tlsa_records() {
  local nameserver
  nameserver=$(dig +short NS "${stalwart_domain}" | sed -n '1p')
  if [[ ! ${nameserver} =~ ^[A-Za-z0-9.-]+\.$ ]]; then
    return 1
  fi
  dig +short +tcp "@${nameserver}" \
    "_25._tcp.${stalwart_hostname}" TLSA
}

tlsa_matches_live_certificate() {
  local ipv4_spki ipv6_spki records
  ipv4_spki=$(smtp_spki_sha256 -4) || return 1
  ipv6_spki=$(smtp_spki_sha256 -6) || return 1
  if [[ ! ${ipv4_spki} =~ ^[0-9A-F]{64}$ || ${ipv4_spki} != "${ipv6_spki}" ]]; then
    return 1
  fi
  records=$(authoritative_tlsa_records) || return 1
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
  local attempt
  for attempt in $(seq 1 36); do
    if tlsa_matches_live_certificate; then
      printf 'Authoritative DANE TLSA matches the live IPv4 and IPv6 SMTP certificate: verified.\n'
      return 0
    fi
    if ((attempt % 6 == 0)); then
      printf 'Waiting for authoritative DANE TLSA publication (%s/36).\n' "${attempt}"
    fi
    sleep 10
  done
  return 1
}

refresh_production_dns_and_dane() {
  local refresh_attempt
  for refresh_attempt in 1 2 3; do
    # Stalwart v0.16.19 schedules managed DNS reconciliation only when a
    # Domain transitions from manual to automatic DNS management. Reapplying
    # an already-automatic Domain does not retry a failed DNS task.
    bootstrap_stage="production DNS refresh transition ${refresh_attempt}/3"
    apply_plan "${production_dns_refresh_plan}" 'the production-preserving manual DNS refresh transition plan'

    bootstrap_stage="Let's Encrypt production issuance and DNS refresh ${refresh_attempt}/3"
    apply_plan "${production_plan}" 'the production DNS-01 certificate plan'
    wait_for_production_certificate

    bootstrap_stage="authoritative DANE TLSA publication ${refresh_attempt}/3"
    if wait_for_dane_tlsa; then
      return 0
    fi
    if ((refresh_attempt < 3)); then
      printf 'The authoritative SMTP TLSA did not match after DNS refresh attempt %s/3; retrying the managed transition.\n' \
        "${refresh_attempt}" >&2
    fi
  done

  printf 'Timed out waiting for the authoritative DANE TLSA record to match the live SMTP certificate. Recent tasks:\n' >&2
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

if production_certificate_is_valid -4 && production_certificate_is_valid -6 && \
  tlsa_matches_live_certificate; then
  printf 'Production certificate and authoritative DANE TLSA already match: verified.\n'
else
  refresh_production_dns_and_dane
fi

bootstrap_stage='public enforcing MTA-STS policy audit'
wait_for_enforcing_mta_sts_policy

mail_policy_matches() {
  local apex_rrset dmarc_rrset domain_metadata mail_rrset mta_sts_rrset
  local legacy_autoconfig_status published tls_reporting_rrset
  domain_metadata=$(desec_api_request GET "domains/${stalwart_domain}/") || return 1
  apex_rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/@/CAA/") || return 1
  mail_rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/mail/CAA/") || return 1
  mta_sts_rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/mta-sts/CNAME/") || return 1
  dmarc_rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/_dmarc/TXT/") || return 1
  tls_reporting_rrset=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/_smtp._tls/TXT/") || return 1
  legacy_autoconfig_status=$(desec_api_request GET \
    "domains/${stalwart_domain}/rrsets/autoconfig/CNAME/" status) || return 1
  [[ ${legacy_autoconfig_status} == 404 ]] || return 1
  published=$(jq -er '.published | select(type == "string")' \
    <<<"${domain_metadata}") || return 1

  jq -e --arg published "${published}" '
    .subname == ""
    and .type == "CAA"
    and (.records | sort) == ([
      "0 iodef \"mailto:caa@thefutureisprivate.dev\"",
      "128 issue \";\"",
      "128 issuemail \";\"",
      "128 issuevmc \";\"",
      "128 issuewild \";\""
    ] | sort)
    and (.touched <= $published)
  ' <<<"${apex_rrset}" >/dev/null || return 1

  jq -e \
    --arg account_uri "${production_account_uri}" \
    --arg published "${published}" '
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
      and (.touched <= $published)
    ' <<<"${mail_rrset}" >/dev/null || return 1

  jq -e --arg target "${stalwart_hostname}." '
    .subname == "mta-sts"
    and .type == "CNAME"
    and .records == [$target]
  ' <<<"${mta_sts_rrset}" >/dev/null || return 1

  jq -e --arg published "${published}" '
    .subname == "_dmarc"
    and .type == "TXT"
    and .records == ["\"v=DMARC1; p=reject; rua=mailto:dmarc@thefutureisprivate.dev\""]
    and (.touched <= $published)
  ' <<<"${dmarc_rrset}" >/dev/null || return 1

  jq -e --arg published "${published}" '
    .subname == "_smtp._tls"
    and .type == "TXT"
    and .records == ["\"v=TLSRPTv1; rua=mailto:tls-rpt@thefutureisprivate.dev\""]
    and (.touched <= $published)
  ' <<<"${tls_reporting_rrset}" >/dev/null
}

wait_for_mail_policy() {
  local attempt
  for attempt in $(seq 1 180); do
    if mail_policy_matches; then
      printf 'Published CAA, DMARC, and TLS-RPT policy: verified.\n'
      return 0
    fi
    if ((attempt % 15 == 0)); then
      printf 'Waiting for deSEC to publish the exact mail policy (%s/180).\n' \
        "${attempt}"
    fi
    if ((attempt < 180)); then
      sleep 2
    fi
  done
  printf 'Timed out waiting for deSEC to publish the exact mail policy.\n' >&2
  return 1
}

bootstrap_stage='deSEC CAA and reporting publication audit'
wait_for_mail_policy

bootstrap_stage='production DNS and ACME audit'
capture_cli query AcmeProvider \
  --fields directory,accountUri,challengeType,contact \
  --json |
  jq -e -s --arg account_uri "${production_account_uri}" '
    any(.[];
      .directory == "https://acme-v02.api.letsencrypt.org/directory"
      and .challengeType == "Dns01"
      and .accountUri == $account_uri
    )
  ' >/dev/null

capture_cli query Domain \
  --fields name,certificateManagement,dkimManagement,dnsManagement,dnsZoneFile,reportAddressUri \
  --json |
  jq -e -s --arg domain "${stalwart_domain}" --arg hostname "${stalwart_hostname}" '
    any(.[];
      .name == $domain
      and .certificateManagement."@type" == "Automatic"
      and .certificateManagement.subjectAlternativeNames == {"mail": true, "mta-sts": true}
      and .dkimManagement."@type" == "Automatic"
      and .dnsManagement."@type" == "Automatic"
      and .dnsManagement.origin == $domain
      and .dnsManagement.publishRecords.caa == false
      and .dnsManagement.publishRecords.dmarc == false
      and .dnsManagement.publishRecords.tlsRpt == false
      and .dnsManagement.publishRecords.autoConfigLegacy == false
      and .dnsManagement.publishRecords.dkim == true
      and .dnsManagement.publishRecords.tlsa == true
      and .reportAddressUri == null
      and (.dnsZoneFile | contains($hostname))
    )
  ' >/dev/null

capture_cli get MtaSts --fields mode,maxAge,mxHosts --json |
  jq -e '
    .mode == "enforce"
    and .maxAge == 604800000
    and .mxHosts == {}
  ' >/dev/null

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
