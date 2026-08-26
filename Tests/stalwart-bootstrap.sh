#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
initial_plan="${repo_root}/Stalwart/bootstrap-initial.ndjson"
staging_plan="${repo_root}/Stalwart/bootstrap-staging.ndjson"
production_plan="${repo_root}/Stalwart/bootstrap-production.ndjson"
production_dns_refresh_plan="${repo_root}/Stalwart/bootstrap-production-dns-refresh.ndjson"
mta_sts_plan="${repo_root}/Stalwart/mta-sts.ndjson"

for plan in \
  "${initial_plan}" \
  "${staging_plan}" \
  "${production_plan}" \
  "${production_dns_refresh_plan}"; do
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
  map(.object) == ["DnsServer", "AcmeProvider", "Domain", "SystemSettings", "Application"]
  and (.[1].value | keys) == ["letsencrypt-production"]
  and .[1].value["letsencrypt-production"].directory
    == "https://acme-v02.api.letsencrypt.org/directory"
  and .[2].value.primary.certificateManagement == {
    "@type": "Automatic",
    "acmeProviderId": "#letsencrypt-production",
    "subjectAlternativeNames": {"mail": true, "mta-sts": true}
  }
  and .[2].value.primary.dnsManagement == {"@type": "Manual"}
  and (tostring | contains("acme-staging-v02") | not)
' "${production_dns_refresh_plan}" >/dev/null

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
  and .[3].value.primary.dkimManagement."@type" == "Automatic"
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
      "subjectAlternativeNames": {"mail": true, "mta-sts": true}
    }
    and .[2].value.primary.dnsManagement."@type" == "Automatic"
    and .[2].value.primary.dnsManagement.origin == "thefutureisprivate.dev"
    and (.[2].value.primary.dnsManagement.publishRecords | keys | sort) == [
      "autoConfig", "autoConfigLegacy", "autoDiscover", "caa", "dkim", "dmarc",
      "mtaSts", "mx", "spf", "srv", "tlsRpt", "tlsa"
    ]
    and .[2].value.primary.dnsManagement.publishRecords.caa == false
    and .[2].value.primary.dnsManagement.publishRecords.dmarc == false
    and .[2].value.primary.dnsManagement.publishRecords.tlsRpt == false
    and .[2].value.primary.dnsManagement.publishRecords.autoConfigLegacy == false
    and .[2].value.primary.dnsManagement.publishRecords.tlsa == true
    and .[2].value.primary.reportAddressUri == null
  ' "${plan}" >/dev/null
done

grep -Fq -- '-target=desec_token_policy.stalwart_mail_records' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-target=desec_rrset.apex_caa' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '-target=desec_rrset.mail_caa' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "-target='desec_rrset.imported_zone[\"dmarc\"]'" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- "-target='desec_rrset.imported_zone[\"tls_reporting\"]'" \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'stalwart_acme_account_uri: $account_uri' \
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
if grep -Eq '^[[:space:]]*(dmarc|tls_reporting)[[:space:]]*=' \
  "${repo_root}/OpenTofu/dns.tf"; then
  printf 'The Stalwart child token must not retain DMARC or TLS-RPT write authority.\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*legacy_autoconfig[[:space:]]*=' \
  "${repo_root}/OpenTofu/dns.tf"; then
  printf 'The Stalwart child token must not retain legacy autoconfiguration write authority.\n' >&2
  exit 1
fi
grep -Fq -- 'mailto:caa@thefutureisprivate.dev' "${repo_root}/OpenTofu/dns.tf"
grep -Fq -- 'mailto:dmarc@thefutureisprivate.dev' "${repo_root}/OpenTofu/zone.tf"
grep -Fq -- 'mailto:tls-rpt@thefutureisprivate.dev' "${repo_root}/OpenTofu/zone.tf"
grep -Fq -- 'wait_for_staging_certificate' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_production_certificate' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'wait_for_dane_tlsa' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'authoritative_tlsa_records' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'smtp_spki_sha256 -4' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'smtp_spki_sha256 -6' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'the production-preserving manual DNS refresh transition plan' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'apply_plan "${production_dns_refresh_plan}"' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
if grep -Fq -- 'already_production' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Public reachability must not decide whether bootstrap re-enters staging.\n' >&2
  exit 1
fi
if [[ $(grep -Fc -- 'if [[ ${first_rollout} == true ]]; then' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh") -ne 3 ]]; then
  printf 'Initial declaration, staging-account inspection, and staging transition must be first-rollout-only.\n' >&2
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
grep -Fq -- 'desec_api_request DELETE' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'rrsets/autoconfig/CNAME/' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'curl_args=(--silent --show-error --request "$1" --config -)' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '.touched <= $published' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'env -u DESEC_API_TOKEN curl' \
  "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- '.dnsManagement.publishRecords.autoConfigLegacy == false' \
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
if grep -Fq -- 'run_cli create Task/AcmeRenewal' "${repo_root}/Scripts/stalwart-bootstrap.sh"; then
  printf 'Production issuance must rely on the automatic task after staging retirement.\n' >&2
  exit 1
fi
grep -Fq -- 'distrobox-host-exec podman' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'type=env,target=STALWART_PASSWORD' "${repo_root}/Scripts/stalwart-bootstrap.sh"
grep -Fq -- 'container_engine podman secret rm' "${repo_root}/Scripts/stalwart-bootstrap.sh"
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
grep -Fq -- 'STALWART_BOOTSTRAP_SECRET_NAME must name the temporary server-side Podman secret.' \
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
printf 'Stalwart automated bootstrap policy: OK\n'
