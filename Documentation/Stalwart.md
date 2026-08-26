# Stalwart Production Setup

## Production Identity

Use these values during the Stalwart setup flow:

| Setting | Value |
| --- | --- |
| Server hostname | `mail.thefutureisprivate.dev` |
| Primary mail domain | `thefutureisprivate.dev` |
| Initial mailbox | `contact@thefutureisprivate.dev` |
| Administrator contact | `contact@thefutureisprivate.dev` |
| Account management | Stalwart Web UI |

The public services are SMTP federation on 25,
HTTPS/JMAP/CalDAV/CardDAV/WebDAV/admin on 443, implicit-TLS submission on 465,
and IMAPS on 993. Authenticated clients must use 443, 465, or 993, where TLS
1.3 begins with the first byte. Port 25 cannot use
implicit TLS because Internet SMTP delivery begins in cleartext and upgrades
with STARTTLS. The server advertises STARTTLS but refuses `MAIL FROM` until the
upgrade succeeds. It offers TLS 1.2 and TLS 1.3 for interoperability with other
mail servers; Stalwart authentication is disabled there, so it is not a
client-submission exception. POP3, ManageSieve, cleartext HTTP, ports 143 and
587, and any other listener are deliberately absent. Outbound SMTP TLS policy
is unchanged and continues to negotiate with receiving mail servers.

The Quadlet pins `STALWART_HOSTNAME` to the unique Ansible inventory name
(`mail-01` for this node). Stalwart uses that value only for its cluster-node
lease; the public protocol identity remains `mail.thefutureisprivate.dev`.
Container recreation therefore renews one stable lease instead of registering
the new container ID as another cluster node.

This mirrors GrapheneOS's current receiving policy: its Postfix
[`smtpd_tls_security_level = encrypt`](https://github.com/GrapheneOS/mail.grapheneos.org/blob/main/postfix/main.cf#L66)
requires STARTTLS for inbound SMTP, while its inbound protocol floor remains
TLS 1.2. Its authenticated
[`submissions` service](https://github.com/GrapheneOS/mail.grapheneos.org/blob/main/postfix/master.cf#L7-L18)
raises that floor to TLS 1.3. Requiring STARTTLS on port 25 intentionally rejects
delivery from legacy mail servers which cannot negotiate TLS 1.2 or newer.

## Secure Bootstrap

Run the automated bootstrap from the repository:

```bash
make stalwart-bootstrap
```

The target generates a new 256-bit password for a one-run recovery
administrator. It sends the combined credential over SSH standard input into
a randomly named rootful Podman secret and references that secret only from the
temporary bootstrap Quadlet. Inside Distrobox, a second transient host-Podman
secret supplies the password to the pinned CLI without placing it in a process
argument. It owns the entire listener and secret lifecycle, creates the
authenticated SSH forward, and uses the CLI only over loopback. It installs
the checksum-verified `file:///opt/stalwart-webui/webui.zip` Application,
configures server identity,
deSEC, automatic DKIM, staging and production DNS-01 ACME, applies exact DKIM
selector token policies, verifies the trusted public certificate and
OpenTofu-owned apex/mail CAA policy, and restores the production Quadlet on
every exit.
Before DNS publication it reconciles listeners to the requested protocols plus
the temporary management endpoint, so Stalwart never requests deSEC authority
for POP3, ManageSieve, cleartext IMAP, or cleartext submission SRV records. It
performs the staging-to-production transition only on the first rollout: it
returns certificate management to Manual, deletes only the verified staging
certificate for the public hostname, and enables the production provider. The
automatically scheduled production issuance can no longer be postponed by
Stalwart's valid-certificate freshness guard.

At the final handoff the target displays the one-run recovery credential. Open
`https://mail.thefutureisprivate.dev/admin`, create or repair a regular account
with the built-in Admin role, sign out, and prove that the regular login works.
Only then press Enter. The target verifies that a regular Admin account exists,
restarts Stalwart without the recovery environment, and removes both transient
secrets. Stalwart explicitly treats `STALWART_RECOVERY_ADMIN` as a backdoor, so
it is never retained in the production Quadlet. If that production restart
fails, the script leaves the named server secret intact and reports it instead
of pretending the active recovery credential was revoked; repair with
`make deploy` before deleting the reported secret.

Ansible verifies Web UI v1.0.8 against SHA-256
`a3904b571aacca815eee2c38dd86de510d53304babe50b9576760bf70a36c0bf`
before mounting it read-only. Store the regular administrator's unique password
in a password manager. Port 8080 is never exposed publicly.

## Declarative Hardening

Run this step after `make stalwart-bootstrap` has verified the permanent
certificate at `https://mail.thefutureisprivate.dev`. The plan in
`Stalwart/hardening.ndjson` reconciles the complete listener set, so applying it
also removes Stalwart's bootstrap HTTP, POP3S, and ManageSieve defaults. The
HTTPS listener serves JMAP and all DAV protocols without another port or
listener.

The CSP authorizes Stalwart's pinned login bootstrap script by its exact
SHA-256 hash; it does not enable general inline script execution. Recalculate
and review that hash when upgrading the Stalwart image if the upstream login
page changes.

In the administrator UI, create an API key for the administrator account under
Account › Credentials › API Keys. Name it `infrastructure-hardening`, use
`Replace` permission mode, and grant exactly:

- `authenticate`;
- `sysNetworkListenerGet`;
- `sysNetworkListenerCreate`;
- `sysNetworkListenerUpdate`;
- `sysNetworkListenerDestroy`;
- `sysNetworkListenerQuery`;
- `sysMtaInboundThrottleGet`;
- `sysMtaInboundThrottleCreate`;
- `sysMtaInboundThrottleUpdate`;
- `sysMtaInboundThrottleQuery`;
- `sysMtaQueueQuotaGet`;
- `sysMtaQueueQuotaCreate`;
- `sysMtaQueueQuotaUpdate`;
- `sysMtaQueueQuotaQuery`;
- `sysHttpGet`;
- `sysHttpUpdate`;
- `sysImapGet`;
- `sysImapUpdate`;
- `sysJmapGet`;
- `sysJmapUpdate`;
- `sysAuthenticationGet`;
- `sysAuthenticationUpdate`;
- `sysWebDavGet`;
- `sysWebDavUpdate`;
- `sysMtaStageAuthGet`;
- `sysMtaStageAuthUpdate`;
- `sysMtaStageMailGet`;
- `sysMtaStageMailUpdate`;
- `sysMtaStsGet`;
- `sysMtaStsUpdate`;
- `sysActionCreate`;
- `sysApplicationGet`;
- `sysApplicationCreate`;
- `sysApplicationUpdate`;
- `sysApplicationDestroy`;
- `sysApplicationQuery`.

Restrict `allowedIps` to the operator workstation's stable public egress CIDR
when one is available. The server reveals the API-key secret only once. Store
it immediately as `STALWART_CONFIG_API_TOKEN` with `make sops-mail-edit`; never
place it in a shell command, `.env` file, or Quadlet. This key cannot log in to
mail protocols and has no account, domain, DNS, queued-message, or
secret-management permissions. Its queue authority is limited to quota
configuration and cannot inspect, retry, pause, resume, or destroy queued mail.

Apply and verify the plan, then reconcile the production Quadlet:

```bash
make stalwart-harden
make deploy
make stalwart-audit
```

The managed `Sender IP throttle` permits 25 new SMTP sessions per second from
one remote IP. Stalwart's default of five silently closes the sixth connection
before the SMTP greeting, which breaks standards scanners such as Internet.nl
and can also disrupt bursty, legitimate receiving MTAs. Per-IP throttling,
listener connection limits, and Stalwart's separate abuse and scanner bans
remain enabled; no external sender is placed on a permanent allowlist.

Two additional throttles apply to every authenticated submission, including
implicit-TLS SMTP submission and JMAP `EmailSubmission`. Each account can submit
at most 100 messages per hour and 500 per day across those paths. A queue quota
temporarily rejects new queued mail from a sender domain when that domain reaches
either 5,000 messages or 1 GiB; it never deletes queued mail. Because this
deployment authorizes senders only from its single hosted domain, the quota
bounds normal authenticated outbound mail across all accounts. Stalwart 0.16.19
rejects the documented empty-key encoding for a strictly global queue quota, so
the plan deliberately uses its supported `senderDomain` grouping instead of a
non-applicable global declaration. Unauthenticated SMTP federation remains under
its separate sender-IP throttle.

The authentication singleton explicitly uses Argon2id, requires passwords of at
least 16 characters with Stalwart's `four` zxcvbn strength, and permits at most
two API keys and three application passwords per account. Existing credentials
are not deleted by lowering these creation limits, and existing password hashes
are not guaranteed to be rewritten by a policy update. Change existing account
passwords once after applying the plan when their stored hash or strength is not
already known to comply. IMAP is limited to eight concurrent connections and
1,000 requests per minute per account, with 50 MiB requests. JMAP permits four
concurrent requests, 10,000,000-byte request bodies, and 16 method calls per
request. The HTTP singleton separately retains its authenticated and anonymous
per-minute request limits.

The apply command first reads the live settings. It performs no mutation when
they already match, validates the plan before changing drifted settings, and
audits again afterwards. The audit also checks the live HTTPS headers and
CalDAV, CardDAV, and WebDAV routes. It requires successful TLS 1.3 handshakes
and rejected TLS 1.2 handshakes on ports 443, 465, and 993, then verifies that
SMTP federation on port 25 accepts TLS 1.2 through STARTTLS but rejects a
plaintext `MAIL FROM`. It also reads back the one permitted Application and
fails on Web UI resource drift. The Stalwart Quadlet probes the upstream
`/healthz/live` endpoint every 30 seconds over the production HTTPS listener,
falls back to the loopback-only bootstrap listener during initial setup, and
lets systemd restart the service after three consecutive failures.

The HTTP policy enables Stalwart's one-year HSTS response, disables permissive
CORS and forwarded-IP trust, applies authenticated and anonymous request-rate
limits, prevents framing and MIME sniffing, disables unnecessary browser
capabilities, and prevents sensitive responses from being cached. Its CSP
defaults to no resource access, then permits only same-origin scripts and API
connections, the self-hosted styles and assets required by the pinned WebUI,
and Stalwart's upstream fallback icon. Inline scripts, `eval`, frames, plugins,
and cross-origin API connections remain blocked. `Cross-Origin-Embedder-Policy`
is deliberately not enabled because it would break permitted cross-origin
images unless every upstream response opted in.

The WebDAV policy keeps assisted discovery disabled for standards-compliant,
privacy-preserving principal discovery and explicitly bounds each account to
10 locks, a one-hour lock timeout, 1 KiB dead properties, 250-byte live
properties, 25 MiB request bodies, and 2,000 results per query.

## CalDAV, CardDAV, and WebDAV Clients

Use the permanent HTTPS hostname and a normal Stalwart user account. Accounts
with Stalwart's default `User` role already receive the DAV permissions. If a
custom role is used, it must explicitly retain the required `dav*`
permissions.

Prefer the standard discovery URLs:

| Protocol | URL |
| --- | --- |
| CalDAV | `https://mail.thefutureisprivate.dev/.well-known/caldav` |
| CardDAV | `https://mail.thefutureisprivate.dev/.well-known/carddav` |
| WebDAV files | `https://mail.thefutureisprivate.dev/dav/file/` |

If a client requires a direct collection URL, Stalwart v0.16 uses the full
account address as the principal name and the `@` must be percent-encoded. For
the initial account, use:

```text
https://mail.thefutureisprivate.dev/dav/cal/contact%40thefutureisprivate.dev
https://mail.thefutureisprivate.dev/dav/card/contact%40thefutureisprivate.dev
https://mail.thefutureisprivate.dev/dav/file/contact%40thefutureisprivate.dev
```

Authenticate as `contact@thefutureisprivate.dev` with its Stalwart password.
Create additional accounts in the Web UI and substitute their percent-encoded
full address in direct URLs. Run `make stalwart-harden` after this repository
change, then `make stalwart-audit` to verify all three public DAV routes.

## deSEC and Mail Records

`make stalwart-bootstrap` creates the `DeSEC` DNS Provider with an
environment-variable secret reference named `STALWART_DESEC_API_TOKEN`; it
never writes the token into Stalwart's database. The Quadlet injects that
Podman secret as an environment variable.

The committed declaration configures the `thefutureisprivate.dev` Domain to:

- select automatic DNS management;
- select the deSEC provider;
- set the origin to `thefutureisprivate.dev`;
- publish `dkim`, `tlsa`, `spf`, `mx`, `srv`, `mtaSts`, `autoConfig`, and
  `autoDiscover`;
- disable legacy autoconfiguration and delete its stale `autoconfig` CNAME
  before revoking that owner name from the Stalwart deSEC token;
- leave native `caa`, `dmarc`, and `tlsRpt` publication disabled because
  OpenTofu owns those policy RRsets and can assign a distinct report address
  to each class;
- restrict deSEC TLSA grants to the enabled public listeners at
  `_25._tcp.mail`, `_443._tcp.mail`, `_465._tcp.mail`, `_993._tcp.mail`, and
  `_443._tcp.mta-sts`.

The child token is source-address restricted and grants only the exact
owner-name/type pairs declared by OpenTofu. The bootstrap first creates the
Domain with manual DNS and certificate management so Stalwart can generate its
keys without publishing. It queries every active or retiring selector, writes
them to ignored `OpenTofu/stalwart-dkim.generated.tfvars.json`, applies only the
matching deSEC token policies, and only then enables automatic publication.
Normal `make plan` runs automatically include that generated file, preventing
a later full plan from deleting the selector grants.

Re-run `make stalwart-bootstrap` after a DKIM rotation creates a replacement
selector; it resynchronizes the exact selector set before retrying automatic
publication. Remove a retired selector grant only after Stalwart has completed
the rollover and no longer returns that key. A denied record requires a
reviewed policy change; never add a type-only or wildcard grant.

On an already-production Domain, the bootstrap briefly transitions only DNS
management to manual immediately before restoring automatic DNS. Certificate
management stays automatic and bound to the production provider. Stalwart
v0.16.19 queues a managed DNS reconciliation on that manual-to-automatic
transition; an automatic-to-automatic upsert alone does not retry a failed DNS
task. The bootstrap then waits until deSEC's
authoritative 3-1-1 SMTP TLSA matches the SPKI digest served over both IPv4 and
IPv6. Because Stalwart treats even a transient deSEC 5xx response as a
permanently failed DNS task, bootstrap performs up to three bounded
manual-to-automatic refresh attempts, gives each task a six-minute processing
window, and skips the transition entirely when the authoritative TLSA already
matches.

## TLS and Web UI

The production hardening plan configures the global MTA-STS policy in
`enforce` mode with a seven-day cache. Its MX set remains automatic, so
Stalwart derives the permitted hosts from the managed system settings instead
of duplicating mail-host configuration. `make stalwart-audit` requires the
public policy to contain `mode: enforce`, `max_age: 604800`, and the managed MX
over both IPv4 and IPv6. Configuration updates are activated through
Stalwart's `ReloadSettings` action without restarting the mail service.

The bootstrap creates Let's Encrypt staging and production ACME providers with
DNS-01 through the same deSEC provider and
`contact@thefutureisprivate.dev` as the contact. It proves issuance against
staging only when the managed Domain did not exist when the command began,
then switches the Domain to production and waits for a trusted certificate.
Every rerun keeps the production provider selected even if a public IPv4,
IPv6, or MTA-STS probe fails transiently. A DNS reconciliation retry uses a
separate manual-DNS declaration whose certificate management remains bound to
the production provider, so maintenance cannot temporarily serve a staging
certificate. Stalwart's Domain schema stores SANs as labels relative to the
Domain, so the committed `mail` and `mta-sts` entries request both
`mail.thefutureisprivate.dev` and `mta-sts.thefutureisprivate.dev`. The set is
explicit and non-empty; an empty set would request a wildcard certificate.

Stalwart registers the ACME accounts and exposes their read-only `accountUri`,
which has this production shape:

```text
https://acme-v02.api.letsencrypt.org/acme/acct/<ACCOUNT_ID>
```

The bootstrap writes the URI to the ignored generated OpenTofu input. On the
first rollout it switches the `mail` CAA RRset from staging to production
before production issuance; reruns keep the production account URI throughout.
That RRset is critical, binds both the account URI and `dns-01`, and explicitly
denies wildcard issuance. The critically denying apex remains separate.
Stalwart's `publishRecords.caa`, `publishRecords.dmarc`, and
`publishRecords.tlsRpt` are disabled, and its deSEC token has no permission for
those records. `mta-sts` is a CNAME to `mail`, so both explicit SANs use the
same CAA exception. This split is necessary because Stalwart v0.16 exposes one
shared Domain reporting URI for DMARC, TLS-RPT, and native CAA publication.

Production never points Stalwart at a remote Web UI updater. Ansible verifies
the exact upstream bytes before installing them, the Quadlet mounts the bundle
read-only, and both bootstrap and production hardening reconcile the
Application to the local `file://` URL. A Web UI update is a reviewed URL,
checksum, and declarative-plan change followed by deployment and live audit.

## Production DNS State

Proton Mail is not part of the declared production configuration. Stalwart's
automatic DNS task owns the apex MX and SPF records, DKIM, service discovery,
TLSA, and MTA-STS records, including the `mta-sts` endpoint alias and
`_mta-sts` policy identifier. OpenTofu owns the critically denying apex CAA
RRset, the narrowly authorized `mail` exception, DMARC, and TLS-RPT. Stalwart
retains no write authority over those four policy RRsets.

Create `caa@thefutureisprivate.dev`, `dmarc@thefutureisprivate.dev`, and
`tls-rpt@thefutureisprivate.dev` as aliases in the Web UI before publishing the
records. They can target the existing `contact@thefutureisprivate.dev`
mailbox, while preserving distinct envelope recipients for filtering. Account
and alias lifecycle intentionally remains a Web UI operation. The resulting
destinations are:

| Report class | Address |
| --- | --- |
| CAA `iodef` incidents | `caa@thefutureisprivate.dev` |
| DMARC aggregate reports | `dmarc@thefutureisprivate.dev` |
| SMTP TLS aggregate reports | `tls-rpt@thefutureisprivate.dev` |
| ACME and administrative contact | `contact@thefutureisprivate.dev` |

Review the generated zone file before each DNS task, monitor the task result,
and verify the public records from an independent DNSSEC-validating resolver.
Test inbound SMTP, authenticated outbound submission, IMAP, JMAP, CalDAV,
CardDAV, WebDAV, DKIM, SPF, DMARC, MTA-STS, and TLS-RPT externally after
changes.

Legacy Proton MX, SPF, verification, DKIM, and MTA-STS records must not be
restored as active configuration. Backups are explicitly deferred; production
mail should not become the only copy of irreplaceable data until
application-consistent offsite backups exist.

Stalwart's current DNS model and supported record set are documented in its
[automatic DNS management guide](https://stalw.art/docs/domains/dns-records/),
the [API-key guide](https://stalw.art/docs/auth/authentication/api-key/) defines
credential scoping, the [declarative deployment guide](https://stalw.art/docs/configuration/declarative-deployments/)
defines the plan format, and the [HTTP settings reference](https://stalw.art/docs/http/settings/)
defines global response headers. The
[WebDAV protocol guide](https://stalw.art/docs/http/webdav/) defines the DAV
paths and discovery endpoints, while the
[WebDAV settings guide](https://stalw.art/docs/collaboration/webdav/) defines
the managed limits. The bootstrap flow is described in the [Docker deployment
guide](https://stalw.art/docs/install/platform/docker/).
