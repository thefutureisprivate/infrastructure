# DNS Ownership

## Zone Audit

Export the current source data for an ad hoc audit without exposing the API
token:

```bash
SOPS_SECRETS_FILE=SOPS/infrastructure.sops.yaml \
  bash SOPS/exec-env.sh --allow DESEC_API_TOKEN -- \
  ./Scripts/export-desec-zone.sh thefutureisprivate.dev
```

The exporter writes normalized JSON to standard output and does not modify the
zone. Review it locally or redirect it to an ignored temporary file. Do not
commit full-zone snapshots: OpenTofu and Stalwart are the authoritative
declarations, while a snapshot can retain obsolete records and drift silently.

## Ownership Split

| Owner | Records |
| --- | --- |
| deSEC account | Zone lifecycle, nameservers, DNSSEC keys, and parent delegation |
| OpenTofu | Imported HTTPS, DMARC, and TLS-RPT RRsets, intentional `www` no-mail MX/SPF policy, node A/AAAA records, Hetzner PTR records, apex/mail CAA policy, and exact-name Stalwart token policies |
| Stalwart | Only the explicitly authorized DKIM, SPF, MX, SRV, MTA-STS, autoconfiguration, autodiscovery, TLSA, and ACME-validation owner/type pairs |

`OpenTofu/zone.tf` contains declarative import blocks for six shared RRsets.
On the first apply OpenTofu adopts those exact RRsets instead of trying to
create duplicates. The import blocks remain idempotent afterward.

OpenTofu owns both CAA RRsets. The apex critically denies TLS, wildcard TLS,
S/MIME, and BIMI mark-certificate issuance and retains the incident-report
address:

```text
128 issue ";"
128 issuewild ";"
128 issuemail ";"
128 issuevmc ";"
0 iodef "mailto:caa@thefutureisprivate.dev"
```

The automated bootstrap reads the account URI that Stalwart creates, writes it
to the ignored generated OpenTofu input, and selects staging only during a
first rollout before permanently selecting production. The `mail` override is:

```text
128 issue "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/<ACCOUNT_ID>; validationmethods=dns-01"
128 issuewild ";"
0 issuemail ";"
0 issuevmc ";"
0 iodef "mailto:caa@thefutureisprivate.dev"
```

The empty `issuemail` value denies S/MIME issuance and the empty `issuevmc`
value denies Verified Mark Certificate issuance for BIMI. They are
non-critical only in the `mail` override: this lets an ACME TLS CA ignore
certificate-class tags it does not implement while still requiring it to
honor the critical, account- and method-bound `issue` property. The apex can
make all four denial properties critical because no certificate issuance is
permitted there.

`mta-sts` is a CNAME to `mail`, so CAA processing follows that target and the
same exception covers both explicit certificate SANs. Stalwart's child token
has no CAA permission. OpenTofu also owns the reporting RRsets so each report
class has a distinct destination:

```text
_dmarc      TXT "v=DMARC1; p=reject; rua=mailto:dmarc@thefutureisprivate.dev"
_smtp._tls  TXT "v=TLSRPTv1; rua=mailto:tls-rpt@thefutureisprivate.dev"
```

Stalwart's native DMARC and TLS-RPT publication is disabled, its Domain
reporting URI is cleared, and its child token has no write policy for either
owner name. Every remaining permissive token policy contains an
exact domain, subname, and type. ACME TXT access is limited to the apex and
declared mail and MTA-STS hostnames. TLSA authority is limited to the exact
enabled public listener names at SMTP/25, HTTPS/443, submissions/465,
IMAPS/993, and MTA-STS HTTPS/443.

## Stalwart Mail Records

Proton is absent from the declared production state. Stalwart automatically
reconciles the apex MX/SPF records, DKIM, MTA-STS, and service discovery;
OpenTofu owns DMARC and TLS-RPT. Confirm all of the following whenever that
ownership is enabled or changed:

1. `contact@thefutureisprivate.dev` exists in Stalwart and the administrator can
   sign in over the permanent HTTPS listener.
   The `caa@`, `dmarc@`, and `tls-rpt@` aliases also exist and accept reports.
2. `make stalwart-bootstrap` has synchronized every Stalwart DKIM selector and
   the active ACME account URI into the ignored generated OpenTofu variable
   file; OpenTofu publishes CAA while Stalwart publishes inbound SMTP TLSA.
3. Forward and reverse DNS for `mail.thefutureisprivate.dev` match on IPv4 and
   IPv6, and the TLS certificate is valid.
4. SMTP submission, IMAP, JMAP, inbound SMTP, DKIM, SPF, and DMARC have been
   tested from outside the server.
5. `mta-sts.thefutureisprivate.dev` and `_mta-sts` contain the values generated
   by Stalwart, `_smtp._tls` contains the OpenTofu-managed TLS-RPT policy, and
   the HTTPS MTA-STS policy publishes `mode: enforce`.

Enabling automatic DNS management in Stalwart reconciles entire RRsets and can
replace the apex MX/TXT and mail-policy names. Legacy Proton records must not be
restored into the active zone.

`make stalwart-bootstrap` automates the first-rollout ordering: it creates the
Domain and DKIM keys with publication disabled, reconciles the temporary
listener set to SMTP federation, implicit-TLS submission, IMAPS, HTTPS, and the
loopback-published management listener, and removes Stalwart's POP3,
ManageSieve, cleartext IMAP, and cleartext submission defaults before SRV
generation. It then discovers the exact selectors, writes ignored
`OpenTofu/stalwart-dkim.generated.tfvars.json`, applies only the expanded
child-token policy, and enables automatic DNS. On the first rollout only, it
proves staging ACME, returns certificate management to Manual, removes only the
verified staging certificate for the public hostname, and then enables the
production provider. Stalwart's automatically scheduled production task
therefore cannot defer to a still-valid staging certificate. Reruns preserve
production certificate management throughout DNS refresh. Normal `make plan`
includes the generated DKIM file when present.

Re-run the same target when DKIM rotation creates a replacement selector. It
authorizes every selector still returned by Stalwart before the DNS task is
retried; a later run removes a retired selector policy after Stalwart has
deleted the key. Additional mail domains require the same exact owner-name
enumeration instead of expanding this token across the parent zone.

OpenTofu does not adopt legacy apex or `www` SSHFP placeholders. If all-zero
SHA-256 fingerprints remain in the live zone, they cannot authenticate a real
SSH host key. Verify that nothing relies on them before removal and never use
them to establish SSH trust.
