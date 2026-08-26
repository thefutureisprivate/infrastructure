#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)

jq -e -s '
  length == 13 and
  (map(."@type") == ["reconcile", "upsert", "upsert", "upsert", "update", "update", "update", "update", "update", "update", "update", "update", "reconcile"]) and
  (map(.object) == ["NetworkListener", "MtaInboundThrottle", "MtaQueueQuota", "MtaTlsStrategy", "MtaOutboundStrategy", "Http", "Imap", "Jmap", "Authentication", "WebDav", "MtaStageAuth", "MtaStageMail", "Application"]) and
  (.[0].value | keys | sort == ["https", "imaps", "smtp", "submissions"]) and
  (.[0].value.smtp.tlsImplicit == false) and
  (.[0].value.submissions.tlsImplicit == true) and
  (.[0].value.imaps.tlsImplicit == true) and
  (.[0].value.https.tlsImplicit == true) and
  (.[0].value.smtp.tlsDisableProtocols == {}) and
  (.[0].value.submissions.tlsDisableProtocols == {"tls12": true}) and
  (.[0].value.imaps.tlsDisableProtocols == {"tls12": true}) and
  (.[0].value.https.tlsDisableProtocols == {"tls12": true}) and
  (.[1].matchOn == ["description"]) and
  (.[1].value["sender-ip"] == {
    "enable": true,
    "description": "Sender IP throttle",
    "key": {"remoteIp": true},
    "match": {"else": "true"},
    "rate": {"count": 25, "period": 1000}
  }) and
  (.[1].value["authenticated-submission-hour"] == {
    "enable": true,
    "description": "Authenticated submission hourly limit",
    "key": {"authenticatedAs": true},
    "match": {"else": "!is_empty(authenticated_as)"},
    "rate": {"count": 100, "period": 3600000}
  }) and
  (.[1].value["authenticated-submission-day"] == {
    "enable": true,
    "description": "Authenticated submission daily limit",
    "key": {"authenticatedAs": true},
    "match": {"else": "!is_empty(authenticated_as)"},
    "rate": {"count": 500, "period": 86400000}
  }) and
  (.[2].matchOn == ["description"]) and
  (.[2].value["sender-domain-queue"] == {
    "enable": true,
    "description": "Sender-domain outbound queue limit",
    "key": {"senderDomain": true},
    "match": {"else": "true"},
    "messages": 5000,
    "size": 1073741824
  }) and
  (.[3].matchOn == ["name"]) and
  (.[3].value == {
    "default": {
      "name": "default",
      "description": "Authenticated outbound TLS without certificate bypass",
      "allowInvalidCerts": false,
      "dane": "optional",
      "mtaSts": "optional",
      "startTls": "optional",
      "mtaStsTimeout": 300000,
      "tlsTimeout": 180000
    }
  }) and
  (.[4].value == {"tls": {"match": {}, "else": "\u0027default\u0027"}}) and
  (.[5].value.enableHsts == true) and
  (.[5].value.usePermissiveCors == false) and
  (.[5].value.useXForwarded == false) and
  (.[5].value.responseHeaders["Content-Security-Policy"] | contains("default-src"))
  and (.[5].value.responseHeaders["Content-Security-Policy"] | contains("script-src \u0027self\u0027 \u0027sha256-DN+qOOjtGVsV8lkg72s4vC1jiBzlp3i4PLyWBwwmEBE=\u0027"))
  and (.[5].value.responseHeaders["Content-Security-Policy"] | contains("script-src \u0027unsafe-inline\u0027") | not)
  and (.[6].value == {
    "maxConcurrent": 8,
    "maxRequestRate": {"count": 1000, "period": 60000},
    "maxRequestSize": 52428800
  })
  and (.[7].value == {
    "maxConcurrentRequests": 4,
    "maxRequestSize": 10000000,
    "maxMethodCalls": 16
  })
  and (.[8].value == {
    "passwordHashAlgorithm": "argon2id",
    "passwordMinLength": 16,
    "passwordMinStrength": "four",
    "maxApiKeys": 2,
    "maxAppPasswords": 3
  })
  and (.[9].value == {
    "enableAssistedDiscovery": false,
    "maxLockTimeout": 3600000,
    "maxLocks": 10,
    "deadPropertyMaxSize": 1024,
    "livePropertyMaxSize": 250,
    "requestMaxSize": 26214400,
    "maxResults": 2000
  })
  and (.[11].value.isSenderAllowed.else == "is_tls && (!is_empty(authenticated_as) || !key_exists(\u0027spam-block\u0027, sender_domain))")
  and (.[12].value.webui.resourceUrl == "file:///opt/stalwart-webui/webui.zip")
  and (.[12].value.webui.urlPrefix | keys | sort == ["/account", "/admin"])
' "${repo_root}/Stalwart/hardening.ndjson" >/dev/null

grep -Fq -- 'query MtaTlsStrategy' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'get MtaOutboundStrategy --fields tls' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'show_drift MtaTlsStrategy' \
  "${repo_root}/Scripts/stalwart-hardening.sh"
grep -Fq -- 'show_drift MtaOutboundStrategy' \
  "${repo_root}/Scripts/stalwart-hardening.sh"

printf 'Stalwart hardening plan: OK\n'
