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

This mirrors GrapheneOS's current receiving policy: its Postfix
[`smtpd_tls_security_level = encrypt`](https://github.com/GrapheneOS/mail.grapheneos.org/blob/main/postfix/main.cf#L66)
requires STARTTLS for inbound SMTP, while its inbound protocol floor remains
TLS 1.2. Its authenticated
[`submissions` service](https://github.com/GrapheneOS/mail.grapheneos.org/blob/main/postfix/master.cf#L7-L18)
raises that floor to TLS 1.3. Requiring STARTTLS on port 25 intentionally rejects
delivery from legacy mail servers which cannot negotiate TLS 1.2 or newer.

## Secure Bootstrap

Retrieve the temporary administrator credentials from the host:

```bash
ssh thefutureisprivate@mail.thefutureisprivate.dev \
  sudo journalctl -u mail-stalwart.service --no-pager
```

In a separate terminal, create the only permitted TCP forward:

```bash
ssh -N -L 127.0.0.1:8080:127.0.0.1:8080 \
  thefutureisprivate@mail.thefutureisprivate.dev
```

Run `make deploy-bootstrap` for this stage. Ansible downloads Web UI v1.0.8,
verifies SHA-256
`a3904b571aacca815eee2c38dd86de510d53304babe50b9576760bf70a36c0bf`,
and mounts the bundle read-only. Before loading browser code, run:

```bash
make stalwart-webui-bootstrap
```

The pinned CLI prompts for the temporary password and reconciles the
Application over the loopback tunnel to the verified
`file:///opt/stalwart-webui/webui.zip` resource. Only after its readback check
succeeds should you open `http://127.0.0.1:8080/admin`, replace the temporary
administrator, and store a unique password in a password manager. The normal
`make deploy` target omits this loopback publication.

## Declarative Hardening

Do not run this step until the permanent certificate and
`https://mail.thefutureisprivate.dev` are working. The plan in
`Stalwart/hardening.ndjson` reconciles the complete listener set, so applying it
also removes Stalwart's bootstrap HTTP, POP3S, and ManageSieve defaults. The
HTTPS listener serves JMAP and all DAV protocols without another port or
listener.

In the administrator UI, create an API key for the administrator account under
Account › Credentials › API Keys. Name it `infrastructure-hardening`, use
`Replace` permission mode, and grant exactly:

- `authenticate`;
- `sysNetworkListenerGet`;
- `sysNetworkListenerCreate`;
- `sysNetworkListenerUpdate`;
- `sysNetworkListenerDestroy`;
- `sysNetworkListenerQuery`;
- `sysHttpGet`;
- `sysHttpUpdate`;
- `sysWebDavGet`;
- `sysWebDavUpdate`;
- `sysMtaStageAuthGet`;
- `sysMtaStageAuthUpdate`;
- `sysMtaStageMailGet`;
- `sysMtaStageMailUpdate`;
- `sysApplicationGet`;
- `sysApplicationCreate`;
- `sysApplicationUpdate`;
- `sysApplicationDestroy`;
- `sysApplicationQuery`.

Restrict `allowedIps` to the operator workstation's stable public egress CIDR
when one is available. The server reveals the API-key secret only once. Store
it immediately as `STALWART_CONFIG_API_TOKEN` with `make sops-mail-edit`; never
place it in a shell command, `.env` file, or Quadlet. This key cannot log in to
mail protocols and has no account, domain, DNS, queue, or secret-management
permissions beyond the authentication prerequisite.

Apply and verify the plan, then reconcile the production Quadlet to remove the
bootstrap port publication:

```bash
make stalwart-harden
make deploy
make stalwart-audit
```

The apply command first reads the live settings. It performs no mutation when
they already match, validates the plan before changing drifted settings, and
audits again afterwards. The audit also checks the live HTTPS headers and
CalDAV, CardDAV, and WebDAV routes. It requires successful TLS 1.3 handshakes
and rejected TLS 1.2 handshakes on ports 443, 465, and 993, then verifies that
SMTP federation on port 25 accepts TLS 1.2 through STARTTLS but rejects a
plaintext `MAIL FROM`. It also reads back the one permitted Application and
fails on Web UI resource drift.

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

Create a DNS Provider object with type `DeSEC`. Configure its secret as an
environment-variable reference named `STALWART_DESEC_API_TOKEN`; do not paste
the token into the database. The Quadlet already injects that Podman secret as
an environment variable.

For the `thefutureisprivate.dev` Domain object:

- select automatic DNS management;
- select the deSEC provider;
- set the origin to `thefutureisprivate.dev`;
- publish `dkim`, `spf`, `mx`, `dmarc`, `srv`, `mtaSts`, `tlsRpt`,
  `autoConfig`, `autoConfigLegacy`, and `autoDiscover`;
- exclude `caa`, which remains with OpenTofu;
- exclude `tlsa`; adding it later requires a reviewed exact token policy.

The child token is source-address restricted and grants only the exact
owner-name/type pairs declared by OpenTofu. Copy every active DKIM selector
from Stalwart's reviewed zone output into `stalwart_dkim_selectors` before
applying infrastructure or enabling publication. For DKIM rotation, authorize
the replacement selector first and remove the retired selector only after
rollover. A denied record requires a reviewed policy change; never add a
type-only or wildcard grant.

## TLS and Web UI

Create an ACME provider for Let's Encrypt using DNS-01 through the same deSEC
provider and `contact@thefutureisprivate.dev` as the contact. Test issuance
against the staging directory first, then switch to production. Assign the
certificate to `mail.thefutureisprivate.dev` and verify it on 443, 465, and 993
before accepting users.

After Stalwart registers the production provider, copy the numeric suffix of
its read-only `accountUri` field into `stalwart_acme_account_id` in
`OpenTofu/terraform.tfvars`. A production value has this shape:

```text
https://acme-v02.api.letsencrypt.org/acme/acct/<ACCOUNT_ID>
```

Run `make plan` and `make apply`, then verify both CAA RRsets. The apex denies
ordinary and wildcard issuance. The more-specific `mail` CAA authorizes only
Stalwart's exact Let's Encrypt account and DNS-01 for
`mail.thefutureisprivate.dev`, while wildcard issuance remains denied.
Replacing the ACME account requires updating CAA first.

Production never points Stalwart at a remote Web UI updater. Ansible verifies
the exact upstream bytes before installing them, the Quadlet mounts the bundle
read-only, and both bootstrap and production hardening reconcile the
Application to the local `file://` URL. A Web UI update is a reviewed URL,
checksum, and declarative-plan change followed by deployment and live audit.

## Production DNS State

Proton Mail is not part of the declared production configuration. Stalwart's
automatic DNS task owns the apex MX and mail-policy TXT records, DKIM, service
discovery, TLS reporting, and MTA-STS records, including the `mta-sts` endpoint
alias and `_mta-sts` policy identifier. OpenTofu retains both CAA RRsets and all
other non-authorized DNS names.

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
