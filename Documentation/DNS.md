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
| OpenTofu | HTTPS, canonical MTA-STS/modern-UA aliases, intentional `www` no-mail MX/SPF policy, node A/AAAA records, Hetzner PTR records, apex/mail CAA policy, and exact-name Stalwart token policies |
| Stalwart | Only the explicitly authorized MX, SPF, SRV, Autodiscover, DKIM, TLSA, DMARC, TLS-RPT, atomic MTA-STS and modern-UA CNAME/TXT bundles, Mozilla `autoconfig` CNAME, and ACME-validation owner/type pairs |

`OpenTofu/zone.tf` contains only the steady-state controller-owned RRsets. The
completed one-time state handoff is not retained as compatibility scaffolding;
Stalwart-owned mail RRsets have no OpenTofu resource address.

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

The automated bootstrap requires the account URI that Stalwart creates to
match the reviewed `OpenTofu/stalwart-authority.tfvars.json` value and selects
staging only during a first rollout before permanently selecting production.
The `mail` override is:

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

`mta-sts`, `autoconfig`, `autodiscover`, and `ua-auto-config` are CNAMEs to
`mail`, so CAA processing follows that target and the same exception covers all
explicit certificate SANs. Stalwart's child token has no CAA permission.
Stalwart owns the generated mail-routing, authentication, discovery, and
reporting records; DMARC and TLS-RPT use the shared destination declared on the
Domain and analysed by its report subsystem. CAA retains the separate
OpenTofu-owned `caa@thefutureisprivate.dev` incident destination shown above:

```text
@           MX  10 mail.thefutureisprivate.dev.
@           TXT "v=spf1 mx -all"
mail        TXT "v=spf1 a -all"
autodiscover CNAME mail.thefutureisprivate.dev.
_jmap._tcp        SRV 0 1 443 mail.thefutureisprivate.dev.
_caldavs._tcp     SRV 0 1 443 mail.thefutureisprivate.dev.
_carddavs._tcp    SRV 0 1 443 mail.thefutureisprivate.dev.
_imaps._tcp       SRV 0 1 993 mail.thefutureisprivate.dev.
_submissions._tcp SRV 0 1 465 mail.thefutureisprivate.dev.
_dmarc      TXT "v=DMARC1; p=reject; rua=mailto:reports@thefutureisprivate.dev"
_smtp._tls  TXT "v=TLSRPTv1; rua=mailto:reports@thefutureisprivate.dev"
```

Stalwart's native MX, SPF, SRV, Autodiscover, DMARC, and TLS-RPT publication is
enabled, its Domain reporting URI is `mailto:reports@thefutureisprivate.dev`,
and its child token has exact write policies for only the generated owner/type
pairs. The global report
settings intercept and analyse messages delivered to that address, then
forward them into the dedicated shared mailbox. Every permissive token policy
contains an exact domain, subname, and type. ACME TXT access is limited to the
apex and declared mail and MTA-STS hostnames. TLSA authority is limited to the
exact enabled public listener names at SMTP/25, HTTPS/443, submissions/465,
IMAPS/993, and MTA-STS HTTPS/443.

## Stalwart Mail Records

Proton is absent from the declared production state. Stalwart automatically
reconciles MX, SPF, the enabled TLS-only service SRVs, Outlook Autodiscover,
DKIM, TLSA, the exact MTA-STS and modern-UA CNAME/TXT bundles, Mozilla
autoconfiguration, DMARC, and TLS-RPT. OpenTofu asserts only the canonical
targets of the two bundled aliases. Confirm all of the following whenever that
ownership is enabled or changed:

1. `contact@thefutureisprivate.dev` exists in Stalwart and the administrator can
   sign in over the permanent HTTPS listener. A `reports` Group with address
   `reports@thefutureisprivate.dev` and alias `caa@thefutureisprivate.dev` also
   exists, has the administrator as a member but no administrative role, and
   accepts reports.
2. `make stalwart-bootstrap` has verified every Stalwart DKIM selector and the
   active ACME account URI against the reviewed authority file; OpenTofu
   publishes CAA while Stalwart publishes MX, SPF, SRV, Autodiscover, DMARC,
   TLS-RPT, and inbound SMTP TLSA.
3. Forward and reverse DNS for `mail.thefutureisprivate.dev` match on IPv4 and
   IPv6, and the TLS certificate is valid.
4. SMTP submission, IMAP, JMAP, inbound SMTP, DKIM, SPF, and DMARC have been
   tested from outside the server.
5. `mta-sts.thefutureisprivate.dev` and `_mta-sts` contain the values generated
   by Stalwart, `_smtp._tls` contains the Stalwart-managed TLS-RPT policy for
   `reports@thefutureisprivate.dev`, and
   the HTTPS MTA-STS policy publishes `mode: enforce`.

The child token cannot modify A, AAAA, CAA, HTTPS, `www`, or unrelated records.
As required for native SPF management, its apex TXT grant applies to the whole
DNS RRset; do not place unrelated apex TXT values there without accepting that
Stalwart can reconcile them. Its discovery-alias authority is limited to the
exact Microsoft `autodiscover`, Mozilla `autoconfig`, and the
`mta-sts`/`ua-auto-config` CNAMEs required by enabled publication features.
Legacy Proton records must not be restored into the active zone.

`make stalwart-bootstrap` automates the first-rollout ordering: it creates the
Domain and DKIM keys with publication disabled, reconciles the temporary
listener set to SMTP federation, implicit-TLS submission, IMAPS, HTTPS, and the
loopback-published management listener, and removes Stalwart's POP3,
ManageSieve, cleartext IMAP, and cleartext submission defaults before SRV
generation. It then compares the exact selectors and ACME identity to the
reviewed authority file before enabling automatic DNS. A fresh enrollment is
persistently marked `staged enrollment pending`: the first run can create the
ACME accounts and stop for review, and a later run resumes the staging phase
after their exact account URIs have been committed to the authority file. The
pending marker remains through interruptions and is cleared only by the
production plan. On the first rollout only, the workflow proves staging ACME,
returns certificate management to Manual, removes only the
verified staging certificate for the public hostname, and then enables the
production provider. Stalwart's automatically scheduled production task
therefore cannot defer to a still-valid staging certificate. Reruns preserve
production certificate management throughout DNS refresh. Once the production
certificate and DANE record are verified, the staging provider is removed.

Before a DKIM rotation, add the replacement selector to the reviewed authority
file and apply its exact token policy. A later reviewed change removes the
retired selector policy after Stalwart has deleted the key. Additional mail
domains require the same exact owner-name enumeration instead of expanding
this token across the parent zone.

OpenTofu does not adopt legacy apex or `www` SSHFP placeholders. If all-zero
SHA-256 fingerprints remain in the live zone, they cannot authenticate a real
SSH host key. Verify that nothing relies on them before removal and never use
them to establish SSH trust.
