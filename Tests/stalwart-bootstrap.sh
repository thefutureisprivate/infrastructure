#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
initial_plan="${repo_root}/Stalwart/bootstrap-initial.ndjson"
staging_plan="${repo_root}/Stalwart/bootstrap-staging.ndjson"
production_plan="${repo_root}/Stalwart/bootstrap-production.ndjson"
mta_sts_plan="${repo_root}/Stalwart/mta-sts.ndjson"

# Exercise the shared policy parser and runtime trust boundary directly.
source "${repo_root}/Scripts/lib/stalwart-security.sh"
valid_mta_sts_policy=$'version: STSv1\nmode: enforce\nmx: mail.thefutureisprivate.dev\nmax_age: 604800\n'
stalwart_mta_sts_policy_matches mail.thefutureisprivate.dev \
  "${valid_mta_sts_policy}"
if stalwart_mta_sts_policy_matches mail.thefutureisprivate.dev \
  "${valid_mta_sts_policy}"$'mx: attacker.example\n'; then
  printf 'The MTA-STS verifier accepted an additional MX authorization.\n' >&2
  exit 1
fi
if (export DOCKER_HOST=tcp://attacker.example:2375; stalwart_require_local_podman) \
  >/dev/null 2>&1; then
  printf 'The Stalwart client accepted a remote container runtime endpoint.\n' >&2
  exit 1
fi

for plan in \
  "${initial_plan}" \
  "${staging_plan}" \
  "${production_plan}"; do
  jq -e -s '
    all(.[]; type == "object")
    and all(.[]; ."@type" == "upsert" or ."@type" == "update" or ."@type" == "reconcile")
    and ([.[] | select(.object == "DnsServer")][0].value.desec.secret == {
      "@type": "EnvironmentVariable",
      "variableName": "STALWART_DESEC_API_TOKEN"
    })
    and (tostring | contains("\"@type\":\"Value\"") | not)
  ' "${plan}" >/dev/null
done

jq -e -s '
  length == 1
  and .[0]."@type" == "update"
  and .[0].object == "MtaSts"
  and .[0].value == {"mode": "enforce", "maxAge": 604800000, "mxHosts": {}}
' "${mta_sts_plan}" >/dev/null

jq -e -s '
  map(.object) == ["DnsServer", "AcmeProvider", "NetworkListener", "Domain", "SystemSettings", "Application"]
  and (.[1].value | keys | sort) == ["letsencrypt-production", "letsencrypt-staging"]
  and .[2]."@type" == "reconcile"
  and .[2].matchOn == ["name"]
  and (.[2].value | keys | sort) == ["http", "https", "imaps", "smtp", "submissions"]
  and .[2].value.http.bind == {"[::]:8080": true}
  and .[2].value.http.useTls == false
  and .[2].value.smtp.tlsDisableProtocols == {}
  and .[2].value.submissions.tlsDisableProtocols == {"tls12": true}
  and .[2].value.imaps.tlsDisableProtocols == {"tls12": true}
  and .[2].value.https.tlsDisableProtocols == {"tls12": true}
  and ([.[2].value[] | .protocol] | any(. == "pop3") | not)
  and ([.[2].value[] | .protocol] | any(. == "manageSieve") | not)
  and .[3].value.primary.certificateManagement == {"@type": "Manual"}
  and .[3].value.primary.dnsManagement == {"@type": "Manual"}
  and .[3].value.primary.description == "Primary mail domain (staged enrollment pending)"
  and .[3].value.primary.dkimManagement."@type" == "Automatic"
  and .[3].value.primary.reportAddressUri == "mailto:reports@thefutureisprivate.dev"
  and .[4].value.defaultHostname == "mail.thefutureisprivate.dev"
  and (.[4].value.services | keys | sort) == ["caldav", "carddav", "imap", "jmap", "smtp", "webdav"]
  and .[5].value.webui.resourceUrl == "file:///opt/stalwart-webui/webui.zip"
' "${initial_plan}" >/dev/null

jq -e -s --slurpfile hardening "${repo_root}/Stalwart/hardening.ndjson" '
  .[2].value as $bootstrap
  | ($hardening | map(select(.object == "NetworkListener"))[0].value) as $production
  | ($bootstrap | del(.http)) == $production
' "${initial_plan}" >/dev/null

for specification in \
  "${staging_plan}|https://acme-staging-v02.api.letsencrypt.org/directory|letsencrypt-staging" \
  "${production_plan}|https://acme-v02.api.letsencrypt.org/directory|letsencrypt-production"; do
  IFS='|' read -r plan directory provider_id <<<"${specification}"
  jq -e -s --arg directory "${directory}" --arg provider "#${provider_id}" '
    map(.object) == ["DnsServer", "AcmeProvider", "Domain", "SystemSettings", "Application"]
    and .[1].value[] .directory == $directory
    and .[2].value.primary.certificateManagement == {
      "@type": "Automatic",
      "acmeProviderId": $provider,
      "subjectAlternativeNames": {
        "autoconfig": true,
        "autodiscover": true,
        "mail": true,
        "mta-sts": true,
        "ua-auto-config": true
      }
    }
    and .[2].value.primary.dnsManagement."@type" == "Automatic"
    and .[2].value.primary.dnsManagement.origin == "thefutureisprivate.dev"
    and (.[2].value.primary.dnsManagement.publishRecords | keys | sort) == [
      "autoConfig", "autoConfigLegacy", "autoDiscover", "caa", "dkim", "dmarc",
      "mtaSts", "mx", "spf", "srv", "tlsRpt", "tlsa"
    ]
    and .[2].value.primary.dnsManagement.publishRecords.caa == false
    and .[2].value.primary.dnsManagement.publishRecords.dmarc == true
    and .[2].value.primary.dnsManagement.publishRecords.tlsRpt == true
    and .[2].value.primary.dnsManagement.publishRecords.autoConfigLegacy == true
    and .[2].value.primary.dnsManagement.publishRecords.autoDiscover == true
    and .[2].value.primary.dnsManagement.publishRecords.mx == true
    and .[2].value.primary.dnsManagement.publishRecords.spf == true
    and .[2].value.primary.dnsManagement.publishRecords.srv == true
    and .[2].value.primary.dnsManagement.publishRecords.tlsa == true
    and .[2].value.primary.reportAddressUri == "mailto:reports@thefutureisprivate.dev"
  ' "${plan}" >/dev/null
done

jq -e -s '
  .[2].value.primary.description == "Primary mail domain (staged enrollment pending)"
' "${staging_plan}" >/dev/null
jq -e -s '
  .[2].value.primary.description == "Primary mail domain"
' "${production_plan}" >/dev/null
grep -Fq -- 'capture_cli query Domain --fields name,description --json' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '${domain_description} == "${bootstrap_pending_description}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"

grep -Fq -- '-target=desec_token_policy.stalwart_mail_records' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-parallelism=1' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if [[ $(grep -Fc -- 'select_acme_caa_account "${production_account_uri}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh") -ne 2 ]]; then
  printf 'Bootstrap must reconcile the production deSEC boundary only once per execution path.\n' >&2
  exit 1
fi
grep -Fq -- '-target=desec_rrset.apex_caa' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-target=desec_rrset.mail_caa' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- "-target='desec_rrset.imported_zone[\"dmarc\"]'" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" || \
  grep -Fq -- "-target='desec_rrset.imported_zone[\"tls_reporting\"]'" \
    "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Bootstrap must not retain OpenTofu ownership of DMARC or TLS-RPT.\n' >&2
  exit 1
fi
jq -e '
  .stalwart_dkim_selectors == ["v1-ed25519-20260825", "v1-rsa-20260825"]
  and (.stalwart_acme_account_uri |
    test("^https://acme-v02[.]api[.]letsencrypt[.]org/acme/acct/[0-9]+$"))
  and .stalwart_staging_acme_account_uri == null
' "${repo_root}/OpenTofu/stalwart-authority.tfvars.json" >/dev/null
grep -Fq -- 'Refusing an ACME account that is absent from reviewed controller authority.' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'validationmethods=dns-01' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '128 issue \";\"' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '128 issuewild \";\"' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '128 issuemail \";\"' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '128 issuevmc \";\"' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '0 issuemail \";\"' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '0 issuevmc \";\"' "${repo_root}/OpenTofu/dns.tf"
if grep -Eq '^[[:space:]]*apex_caa[[:space:]]*=' "${repo_root}/OpenTofu/dns.tf"; then
  printf 'The Stalwart child token must not retain CAA write authority.\n' >&2
  exit 1
fi
if ! grep -Fq -- '    dmarc                  = { subname = "_dmarc", type = "TXT" }' \
  "${repo_root}/OpenTofu/dns.tf" || \
  ! grep -Fq -- '    tls_reporting          = { subname = "_smtp._tls", type = "TXT" }' \
    "${repo_root}/OpenTofu/dns.tf"; then
  printf 'The Stalwart child token requires exact DMARC and TLS-RPT write authority.\n' >&2
  exit 1
fi
grep -Fq -- '    legacy_autoconfig      = { subname = "autoconfig", type = "CNAME" }' \
  "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '    mta_sts_alias          = { subname = "mta-sts", type = "CNAME" }' \
  "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- '    user_agent_autoconfig_alias = {' \
  "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- 'subname = "_acme-challenge.autoconfig"' \
  "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- 'subname = "_acme-challenge.autodiscover"' \
  "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- 'subname = "_acme-challenge.ua-auto-config"' \
  "${repo_root}/OpenTofu/dns.tf"
for exact_policy in \
  '    apex_mx                = { subname = "", type = "MX" }' \
  '    apex_spf               = { subname = "", type = "TXT" }' \
  '    mail_spf               = { subname = local.mail_subname, type = "TXT" }' \
  '    autodiscover_alias     = { subname = "autodiscover", type = "CNAME" }' \
  '    jmap_service           = { subname = "_jmap._tcp", type = "SRV" }' \
  '    caldav_service         = { subname = "_caldavs._tcp", type = "SRV" }' \
  '    carddav_service        = { subname = "_carddavs._tcp", type = "SRV" }' \
  '    imaps_service          = { subname = "_imaps._tcp", type = "SRV" }' \
  '    submissions_service    = { subname = "_submissions._tcp", type = "SRV" }'; do
  grep -Fq -- "${exact_policy}" "${repo_root}/OpenTofu/dns.tf"
done
if grep -Eq '_((imap|submission|pop3|pop3s)\._tcp|managesieve\._tcp)' \
  "${repo_root}/OpenTofu/dns.tf"; then
  printf 'The Stalwart child token must not authorize disabled or cleartext service discovery.\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*(apex_mx|apex_spf|mail_spf|autodiscover_alias|jmap_service|caldav_service|carddav_service|imaps_service|submissions_service)[[:space:]]*=' \
  "${repo_root}/OpenTofu/zone.tf"; then
  printf 'OpenTofu must not retain Stalwart-owned mail DNS content.\n' >&2
  exit 1
fi
grep -Fq -- '    user_agent_autoconfig_alias = {' "${repo_root}/OpenTofu/zone.tf"
grep -Fq -- '0 iodef \"mailto:caa@thefutureisprivate.dev\"' \
  "${repo_root}/OpenTofu/dns.tf"
if grep -Fq -- 'v=DMARC1' "${repo_root}/OpenTofu/zone.tf" || \
  grep -Fq -- 'v=TLSRPTv1' "${repo_root}/OpenTofu/zone.tf"; then
  printf 'OpenTofu must not retain DMARC or TLS-RPT record content.\n' >&2
  exit 1
fi
grep -Fq -- 'resource "desec_rrset" "static_zone" {' \
  "${repo_root}/OpenTofu/zone.tf"
if grep -Eq '^[[:space:]]*(import|removed)[[:space:]]*\{' \
  "${repo_root}/OpenTofu/zone.tf"; then
  printf 'Completed DNS state-handoff scaffolding must not remain in the steady-state configuration.\n' >&2
  exit 1
fi
grep -Fq -- 'wait_for_staging_certificate' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_production_certificate' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'for attempt in $(seq 1 360)' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '(."@type" == "DnsManagement" or ."@type" == "AcmeRenewal")' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'and (.status.createdAt // "") >= $since' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_dane_tlsa' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'desec_api_request GET' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'smtp_spki_sha256 -4' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'smtp_spki_sha256 -6' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-verify_hostname "${stalwart_hostname}"' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-verify_return_error' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'run_cli create Task/DnsManagement --stdin' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'schedule_dns_reconciliation false' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'The final Stalwart DNS reconciliation failed:' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '--argjson renew_certificate "${renew_certificate}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
for record_type in spf mx dmarc srv tlsRpt autoDiscover; do
  grep -Fq -- "${record_type}: true" \
    "${repo_root}/Scripts/stalwart-bootstrap.sh"
done
for rrset_selector in \
  "desec_rrset_from_zone '' MX" \
  "desec_rrset_from_zone '' TXT" \
  'desec_rrset_from_zone mail TXT' \
  'desec_rrset_from_zone autodiscover CNAME' \
  'desec_rrset_from_zone _jmap._tcp SRV' \
  'desec_rrset_from_zone _caldavs._tcp SRV' \
  'desec_rrset_from_zone _carddavs._tcp SRV' \
  'desec_rrset_from_zone _imaps._tcp SRV' \
  'desec_rrset_from_zone _submissions._tcp SRV'; do
  grep -Fq -- "${rrset_selector}" "${repo_root}/Scripts/stalwart-bootstrap.sh"
done
grep -Fq -- 'onSuccessRenewCertificate: $renew_certificate' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'status: {"@type": "Pending", due: $due}' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if [[ -e ${repo_root}/Stalwart/bootstrap-production-dns-refresh.ndjson ]]; then
  printf 'The retired manual DNS refresh transition plan still exists.\n' >&2
  exit 1
fi
if grep -Fq -- 'already_production' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Public reachability must not decide whether bootstrap re-enters staging.\n' >&2
  exit 1
fi
if [[ $(grep -Fc -- 'if [[ ${first_rollout} == true ]]; then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh") -ne 4 ]]; then
  printf 'Initial declaration, reviewed authority checks, and staging transition must be first-rollout-only.\n' >&2
  exit 1
fi
grep -Fq -- 'for refresh_attempt in 1 2 3' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_public_endpoints' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'public_endpoint_reachable -4' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'public_endpoint_reachable -6' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'production_certificate_is_valid -4' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'production_certificate_is_valid -6' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_enforcing_mta_sts_policy' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_mail_policy' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'desec_api_request' "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- 'desec_api_request DELETE' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'The bootstrap must not delete Stalwart-managed Mozilla autoconfiguration.\n' >&2
  exit 1
fi
grep -Fq -- '"domains/${stalwart_domain}/rrsets/"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '--dump-header "$headers" --output "$body" --write-out "%{http_code}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'if [[ $http_status == 429 ]]; then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'retry-after:' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'exit 75' "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Eq -- '--retry([ =]|$)|--retry-all-errors|--retry-max-time' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Nested curl retries must not hide deSEC Retry-After from polling callers.\n' >&2
  exit 1
fi
grep -Fq -- 'for attempt in $(seq 1 60)' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'sleep 15' "${repo_root}/Scripts/stalwart-bootstrap.sh"
if sed -n '/mail_policy_matches()/,/^}/p' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" | grep -Fq -- '.touched <= $published'; then
  printf 'Exact DNS audits must not reject deSEC no-op writes whose touched timestamp advances without publication.\n' >&2
  exit 1
fi
if sed -n '/authenticated_tlsa_records()/,/^}/p' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" | grep -Fq -- '.touched <= $published'; then
  printf 'DANE audits must not reject deSEC no-op writes whose touched timestamp advances without publication.\n' >&2
  exit 1
fi
grep -Fq -- 'env -u DESEC_API_TOKEN curl' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if [[ $(grep -Fc -- 'if ((request_status == 75)); then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh") -ne 2 ]]; then
  printf 'Both deSEC polling loops must stop immediately after provider throttling.\n' >&2
  exit 1
fi
grep -Fq -- 'if ((wait_status == 75)); then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
snapshot_line=$(grep -n -m1 'tofu-state-snapshot' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" | cut -d: -f1)
apply_line=$(grep -n -m1 'apply "${tofu_plan}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" | cut -d: -f1)
remove_line=$(grep -n 'rm -f -- "${tofu_plan}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" |
  awk -F: -v start="${apply_line}" '$1 > start { print $1; exit }')
if [[ -z ${snapshot_line} || -z ${apply_line} || -z ${remove_line} ]] || \
   ((apply_line >= snapshot_line || snapshot_line >= remove_line)); then
  printf 'Targeted OpenTofu applies must snapshot encrypted state before deleting the plan.\n' >&2
  exit 1
fi
grep -Fq -- '.dnsManagement.publishRecords.autoConfigLegacy == true' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- 'dnsZoneFile' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Bootstrap must verify published DNS rather than a computed zone-file rendering.\n' >&2
  exit 1
fi
grep -Fq -- 'Production AcmeProvider audit failed; observed managed fields:' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'Production Domain audit failed; observed managed fields:' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '(.dnsManagement.publishRecords.caa // false) == false' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'MtaSts object audit failed; observed managed fields:' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'https://${stalwart_autoconfig_hostname}/mail/config-v1.1.xml' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'https://${stalwart_autodiscover_hostname}/autodiscover/autodiscover.xml' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'https://${stalwart_ua_autoconfig_hostname}/.well-known/user-agent-configuration.json' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'mta_sts_policy_is_enforcing -4' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'mta_sts_policy_is_enforcing -6' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'capture_cli get MtaSts --fields mode,maxAge,mxHosts --json' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'run_cli create Action/ReloadSettings' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'https://mta-sts.' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '/.well-known/mta-sts.txt' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'retire_staging_certificates' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'run_cli delete Certificate --stdin' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'retire_staging_acme_provider' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'run_cli delete AcmeProvider --stdin' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '.directory != "https://acme-staging-v02.api.letsencrypt.org/directory"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- 'run_cli create Task/AcmeRenewal' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Production issuance must rely on the automatic task after staging retirement.\n' >&2
  exit 1
fi
grep -Fq -- 'stalwart_require_local_podman' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'podman --remote=false' "${repo_root}/Scripts/lib/stalwart-security.sh"
grep -Fq -- 'CONTAINER_HOST' "${repo_root}/Scripts/lib/stalwart-security.sh"
grep -Fq -- 'type=env,target=STALWART_PASSWORD' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-L "127.0.0.1:${local_port}:127.0.0.1:8080"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "'https://127.0.0.1:443/healthz/live'" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'bootstrap_probe_status=$(ssh "${ssh_options[@]}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'if [[ ${bootstrap_probe_status} =~ ^[1-5][0-9][0-9]$ ]]; then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if sed -n "/bootstrap_stage='Stalwart bootstrap transport selection'/,/unset bootstrap_probe_status/p" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh" | grep -Fq -- 'https://${stalwart_hostname}'; then
  printf 'Bootstrap transport selection must not depend on the controller public-network path.\n' >&2
  exit 1
fi
grep -Fq -- 'STALWART_BOOTSTRAP_TLS=${bootstrap_tls}' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '--resolve "${stalwart_hostname}:${local_port}:127.0.0.1"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'stalwart_url="https://${stalwart_hostname}:${local_port}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'for attempt in $(seq 1 150)' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "--write-out '%{http_code}'" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'if readiness_status=$(curl "${readiness_args[@]}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- '[[ ${readiness_status} == 200 ]]' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Bootstrap readiness must accept valid HTTP redirects from Stalwart.\n' >&2
  exit 1
fi
grep -Fq -- 'journalctl -u mail-stalwart.service -n 80 --no-pager' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'container_args+=(--add-host "${stalwart_hostname}:127.0.0.1")' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'stalwart_podman secret rm' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'Stalwart CLI error:' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "stalwart_password=\$(openssl rand -hex 32)" "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "sudo podman secret create \"\${remote_password_secret}\" -" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "sudo podman secret rm \"\${remote_password_secret}\"" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'remote_password_secret_created=true' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'production_restored' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'permanent administrator handoff' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'query Account --fields emailAddress,roles --json' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'unset STALWART_PASSWORD' "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Eq '^export STALWART_PASSWORD' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'The Stalwart administrator password must not be exported globally.\n' >&2
  exit 1
fi
if grep -Fq -- '--env "STALWART_PASSWORD=' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'The Stalwart administrator password must not be placed in Podman arguments.\n' >&2
  exit 1
fi
grep -Fq -- "make -C \"\${repo_root}\" deploy-bootstrap" "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "make -C \"\${repo_root}\" deploy" "${repo_root}/Scripts/stalwart-bootstrap.sh"

awk '
  /{% if mail_stalwart_bootstrap_listener \| bool %}/ { in_bootstrap = 1; next }
  /{% endif %}/ { in_bootstrap = 0 }
  /target=STALWART_RECOVERY_ADMIN/ {
    found = 1
    if (!in_bootstrap) {
      exit 1
    }
  }
  END { if (!found) exit 1 }
' "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'PublishPort=127.0.0.1:8080:443' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'PublishPort=127.0.0.1:8080:8080' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
python3 - "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2" <<'PY'
import sys

from jinja2 import Environment, StrictUndefined

template_path = sys.argv[1]
with open(template_path, encoding="utf-8") as handle:
    environment = Environment(undefined=StrictUndefined)
    environment.filters["bool"] = bool
    template = environment.from_string(handle.read())

common = {
    "inventory_hostname": "mail-01",
    "mail_hostname": "mail.example.test",
    "mail_stalwart_bootstrap_secret_name": "bootstrap-secret",
    "mail_stalwart_image": "example.invalid/stalwart@sha256:deadbeef",
    "mail_stalwart_webui_container_path": "/opt/stalwart-webui/webui.zip",
    "mail_stalwart_webui_host_path": "/var/lib/stalwart-webui/webui.zip",
    "quadlet_directory": "/etc/containers/systemd",
}

production = template.render(
    **common,
    mail_stalwart_bootstrap_listener=False,
    mail_stalwart_bootstrap_tls=False,
)
bootstrap_http = template.render(
    **common,
    mail_stalwart_bootstrap_listener=True,
    mail_stalwart_bootstrap_tls=False,
)
bootstrap_tls = template.render(
    **common,
    mail_stalwart_bootstrap_listener=True,
    mail_stalwart_bootstrap_tls=True,
)

assert "PublishPort=127.0.0.1:8080" not in production
assert "PublishPort=127.0.0.1:8080:8080" in bootstrap_http
assert "PublishPort=127.0.0.1:8080:443" not in bootstrap_http
assert "PublishPort=127.0.0.1:8080:443" in bootstrap_tls
assert "PublishPort=127.0.0.1:8080:8080" not in bootstrap_tls
PY
grep -Fq -- 'STALWART_BOOTSTRAP_SECRET_NAME must name the temporary server-side Podman secret.' \
  "${repo_root}/Makefile"
grep -Fq -- 'STALWART_BOOTSTRAP_TLS must be true or false.' \
  "${repo_root}/Makefile"
grep -Fq -- 'Environment=STALWART_HOSTNAME={{ inventory_hostname }}' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HostName={{ inventory_hostname }}' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthCmd=curl -fsSk -H "X-Forwarded-For: 127.0.0.1" https://127.0.0.1:443/healthz/live || curl -fsS -H "X-Forwarded-For: 127.0.0.1" http://127.0.0.1:8080/healthz/live' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthInterval=30s' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthTimeout=5s' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthRetries=3' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthStartPeriod=60s' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'HealthOnFailure=kill' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'Network=mail-dualstack.network' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'Network=mail-postgres.network' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'NoNewPrivileges=true' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'DropCapability=all' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'AddCapability=CAP_NET_BIND_SERVICE' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'MemoryMax=2G' "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'CPUQuota=200%' "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'TasksMax=512' "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'Image={{ mail_stalwart_image }}' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
grep -Fq -- 'Pull=missing' "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"
if grep -Fq -- 'mail-stalwart.build' \
  "${repo_root}/Ansible/quadlets/mail-stalwart.container.j2"; then
  printf 'Stalwart must run the pinned official Alpine image without a host-side build.\n' >&2
  exit 1
fi
for retired_build_input in \
  "${repo_root}/Ansible/quadlets/mail-stalwart.build.j2" \
  "${repo_root}/Ansible/quadlets/mail-stalwart.Containerfile.j2" \
  "${repo_root}/Ansible/quadlets/stalwart-hardening.patch"; do
  if [[ -e ${retired_build_input} ]]; then
    printf 'Retired Stalwart host-build input remains: %s\n' "${retired_build_input}" >&2
    exit 1
  fi
done
if grep -Eq 'mail-stalwart[.-](build|Containerfile)|stalwart-hardening[.]patch' \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"; then
  printf 'Completed Stalwart host-build retirement declarations must not remain.\n' >&2
  exit 1
fi
grep -Fq -- 'Network=mail-postgres.network' \
  "${repo_root}/Ansible/quadlets/mail-postgres.container.j2"
if grep -Fq -- 'Network=mail-dualstack.network' \
  "${repo_root}/Ansible/quadlets/mail-postgres.container.j2"; then
  printf 'PostgreSQL must not join the externally routed mail network.\n' >&2
  exit 1
fi
grep -Fq -- 'Notify=healthy' \
  "${repo_root}/Ansible/quadlets/mail-postgres.container.j2"
grep -Fq -- 'NetworkName=mail-postgres' \
  "${repo_root}/Ansible/quadlets/mail-postgres.network.j2"
grep -Fq -- 'Internal=true' \
  "${repo_root}/Ansible/quadlets/mail-postgres.network.j2"
grep -Fq -- 'mail-postgres.network' \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"
grep -Fq -- "quadlets/mail-postgres.network.j2" \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"
printf 'Stalwart automated bootstrap policy: OK\n'
