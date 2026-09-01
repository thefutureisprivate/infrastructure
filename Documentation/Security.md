# Security Model

## Security Objective

The stack aims to reduce the probability and impact of compromise across four
boundaries: the operator workstation, infrastructure providers, the FCOS host,
and the mail containers. No single control is treated as sufficient.

The primary protected assets are:

- mail data and PostgreSQL contents;
- Stalwart administrator and user credentials;
- Hetzner, Backblaze, Scaleway, and deSEC provider authority;
- the restricted Stalwart deSEC token;
- OpenTofu state;
- the SOPS age private identity;
- DNS and reverse-DNS integrity;
- the repository's pinned deployment inputs.

## Trust Assumptions

The design assumes:

- the operator workstation and its age identity are trusted;
- reviewed repository changes and the default branch are trusted;
- Hetzner Cloud, deSEC, Fedora CoreOS, and selected upstream artifacts are
  trusted within their declared roles;
- the FCOS host and an operator with root access can control all containers and
  their data;
- the configured SSH public key belongs to the intended operator;
- OpenTofu state is stored with confidentiality and integrity appropriate to a
  secret-bearing artifact.

gVisor is a defense-in-depth boundary against container compromise. It does not
protect containers from a malicious host administrator or make an untrusted
container image safe by itself.

## Workstation Controls

The Silverblue profile reduces mutable host state rather than treating the
operator workstation as another conventional package-managed server. It stages
rpm-ostree updates for the next user-initiated reboot, layers only explicitly
declared host-integration and administration packages, and leaves other
development tools in Toolbx. Automatic reboots are rejected so an update cannot
interrupt an active deployment or secret-handling operation.

The workstation also applies a compatibility-scoped version of the PrivSec
desktop hardening baseline. It enforces SELinux, signed modules and kernel
lockdown, IOMMU isolation, memory and information-leak sysctls, NTS time,
DNSSEC/opportunistic DNS-over-TLS without LLMNR, randomized link identities,
PAM faillock, private file-creation defaults, and disabled GNOME media autorun.
Its firewalld zone drops unsolicited inbound traffic while retaining only the
discovery client protocols required for printing and scanning. The SSH server
and Fedora CountMe timer are masked.

Controls that conflict with declared workstation capabilities are explicitly
excluded: user namespaces and container/VM kernel interfaces remain available;
Bluetooth and CIFS modules are not denied; strict reverse-path filtering is not
used with WireGuard/libvirt; and Flatpak permissions are not globally revoked
without per-application review. Full-disk encryption and Secure Boot are
reported as audit boundaries because a running Ansible role cannot safely
establish their installation and firmware trust roots.

Flatpak remotes and applications are installed in the invoking user's scope.
Repository definitions must use HTTPS, and existing remotes and applications
must match their declared effective source. A mismatch stops reconciliation;
the operator must explicitly remove the old state before establishing a new
trust root. Undeclared package layers and Flatpaks are not pruned, so adopting
the profile cannot silently remove local software.

## Host Controls

The same mail-independent Ignition applies to every declared FCOS node. It
uses administrator drop-ins wherever Fedora exposes them; chrony needs one
appended `confdir` directive because Fedora 44 does not load a configuration
drop-in directory by default. The baseline includes:

- automatic CPU vulnerability mitigations with SMT disabled;
- allocation initialization, stack randomization, page-table isolation, and
  slab-merging restrictions, plus forced pointer hashing and ptrace-gated
  `/proc/<pid>/mem` writes;
- kernel lockdown confidentiality mode and signed-module enforcement;
- disabled debugfs, legacy 32-bit execution, trusted CPU/bootloader entropy,
  kexec loading, unprivileged BPF, userfaultfd, and unrestricted kernel-pointer
  access;
- hardened redirect, source-route, martian logging, reverse-path, SYN-cookie,
  and IPv6 network settings while retaining forwarding required by Podman;
- denial of unused network protocol, remote filesystem, physical-device, and
  kernel test modules while preserving Hetzner and Podman dependencies;
- authenticated chrony time from an NTS quorum with no command listener;
- authenticated Cloudflare DNS-over-TLS with local DNSSEC validation, no
  plaintext fallback, and no LLMNR or multicast-DNS resolution;
- persistent, sealed, compressed journals bounded to 512 MiB and 14 days;
- disabled process core dumps and masked coredump, debug-shell, kdump, and
  rpm-ostree count-me units, plus disabled automatic SSH socket generation;
- enforcing host SELinux; the two gVisor containers alone disable unsupported
  OCI process labels and rely on the userspace-kernel sandbox instead.

The sysctl policy keeps `kernel.yama.ptrace_scope=1`, which is compatible with
gVisor's default systrap platform. Strict reverse-path filtering is avoided
because it can break container routing; loose filtering remains enabled.

## SSH Boundary

The shared Hetzner base firewall exposes TCP 22 to all IPv4 and IPv6 sources because SSH
must remain reachable from everywhere. The SSH daemon compensates with:

- public-key authentication as the only accepted method;
- disabled root, password, keyboard-interactive, GSSAPI, and host-based login;
- disabled agent, remote, X11, and tunnel forwarding, with local forwarding
  restricted to `127.0.0.1:8080` for the Stalwart bootstrap;
- login restricted to `thefutureisprivate`, with bounded authentication
  attempts, sessions, startup pressure, and idle time;
- Ansible host-key verification against a repository-local ignored trust file.

Internet-wide reachability remains a deliberate attack-surface tradeoff. Key
protection, prompt revocation, host-key verification, and monitoring remain
operator responsibilities.

Mail application ports live in a second firewall attached only to
`mail_server_node_key`. Other VPS nodes receive the same host hardening without
receiving mail ingress or membership in the Ansible `mail` group.

OpenTofu creates IPv4 and IPv6 addresses as explicit Hetzner Primary IP
resources before creating each server. Both address families disable automatic
deletion, enable Hetzner deletion protection, and use `prevent_destroy` so a
server deletion cannot silently discard a stable address. Existing deployments
adopt their current resource IDs through `primary_ip_import_ids` while retaining
their existing attachment marker: the hcloud provider's automatic-to-explicit
transition would otherwise unassign and try to delete the same live address.
New nodes attach the protected Primary IP resources explicitly at creation.

## Direct Installation Boundary

OpenTofu creates the final server and an operator SSH-key resource from the
same public key embedded by Butane. The server initially uses a native Hetzner
image only so it can exist as a cloud resource; the direct installer enables
`linux64` Rescue through the authenticated API and overwrites that final
server's disk with FCOS.

The destructive step is constrained by several independent checks:

- OpenTofu must output the exact server ID, name, and assigned address;
- the live API object must match that identity;
- `fcos-installation` must be `pending` or an interrupted `installing` state;
- the remote destination must match a narrow block-device allowlist and have
  no mounted filesystems;
- the transferred runtime bundle, Ignition document, and installer binary are
  checked by SHA-256 before execution;
- coreos-installer runs without `--insecure`, so Fedora's image signature must
  validate;
- after installation the marker remains `awaiting-verification` until a
  separately obtained permanent host key is present in
  `Ansible/inventory/known_hosts` and strict SSH observes Fedora CoreOS,
  `VARIANT_ID=coreos`, an ostree boot, working non-interactive operator sudo,
  and gVisor runtime readiness; only then does it change to `installed`.

The key-only `thefutureisprivate` operator receives a user-specific
`NOPASSWD` sudoers drop-in because Ansible reconciles root-owned host state.
The operator's private SSH key is therefore a root-equivalent credential. The
rule does not change Fedora's packaged sudo configuration or grant the same
authority to every member of `wheel`.

OpenTofu ignores drift only for that single installation-marker map element;
all other server labels remain managed. A server marked `installed` is skipped
unless the operator explicitly sets `FCOS_REINSTALL=1`. An interrupted run is
retryable because its marker remains `installing`.

Hetzner generates a temporary SSH host key for every Rescue boot. Automation
accepts it only into an isolated, deleted-on-exit known-hosts file. This is
temporary trust on first use, not independent host authentication. Rescue
receives no SOPS values or application credentials: only the public Ignition
configuration and digest-pinned installer runtime cross that connection. The
permanent FCOS verification uses `StrictHostKeyChecking=yes` against the
repository inventory pin; an absent or mismatched pin leaves the authenticated
cloud marker at `awaiting-verification` and blocks normal deployment.

## Container Boundary

Both Stalwart and PostgreSQL use the explicitly registered `runsc` OCI runtime.
The containers require `gvisor-install.service`, so a missing or failed runtime
installation blocks application startup rather than silently falling back to
the default runtime.

Stalwart runs the official Alpine image at the exact reviewed version and
immutable digest declared in `Ansible/compose.yaml`. The VPS never compiles or
derives a Stalwart image; upgrades are limited to reviewed upstream artifacts.

The installer:

- uses an immutable release URL rather than `latest`;
- requires HTTPS with TLS 1.2 or newer;
- retries transient failures without accepting HTTP errors;
- verifies a pinned SHA-512 digest before extraction;
- requires the new multi-file bundle layout and adjacent sidecars;
- keeps host SELinux enforcing while only the two gVisor Quadlets disable the
  unsupported per-container process label;
- runs as a hardened one-shot systemd unit with a read-only filesystem except
  for its explicit installation paths.

Both Quadlets add read-only roots, bounded tmpfs mounts, named persistent
volumes, and no-new-privileges. Stalwart alone joins the externally routed mail
network and reaches PostgreSQL over a separate Podman network marked internal;
PostgreSQL has no published host port and joins a second bridge only for
outbound encrypted backup traffic when backups are enabled.
Stalwart runs as the image's unprivileged UID 2000, drops Podman's default
capabilities, and receives only `CAP_NET_BIND_SERVICE`, which the upstream image
requires for privileged mail ports. It publishes only the services selected in
OpenTofu variables. Its bootstrap HTTP publication is disabled by default and
can be enabled only on host loopback for initial setup. Both containers expose
internal health checks. PostgreSQL delays its systemd-ready notification until
its readiness probe passes. Stalwart's probe uses the upstream liveness endpoint
over HTTPS, falls back to the loopback bootstrap listener only while it exists,
and kills the container after three failures so the systemd restart policy can
recover it.

## Stalwart Boundary

The production plan reconciles the listener collection rather than merely
adding preferred listeners. Only federated SMTP on 25,
HTTPS/JMAP/CalDAV/CardDAV/WebDAV/admin on 443, implicit-TLS submission on 465,
and IMAPS on 993 survive reconciliation. POP3, ManageSieve, cleartext HTTP, and
STARTTLS client ports 143 and 587 are removed.
SMTP port 25 remains non-implicit for Internet federation, but AUTH is disabled
on that port and the MAIL stage rejects senders until STARTTLS succeeds. SMTP
client authentication of every kind is offered only when TLS is already active
on a non-federation listener.

The authenticated client listeners on ports 443, 465, and 993 disable TLS 1.2
and therefore require TLS 1.3. The port 25 federation listener deliberately
keeps both TLS 1.2 and TLS 1.3 available for inbound server-to-server STARTTLS;
the upgrade is mandatory before message transfer. This matches GrapheneOS's
receiving policy while preserving compatibility with TLS 1.2-speaking MTAs.
Outbound SMTP remains opportunistic for recipients without DANE or MTA-STS, but
the selected TLS strategy always validates certificates and has no retry branch
to Stalwart's permissive `invalid-tls` strategy. Stalwart's TLS library does not
offer TLS 1.0 or TLS 1.1 on any listener.

Stalwart performs external MTA resolution through its Cloudflare DNS-over-TLS
backend with EDNS and TCP fallback enabled. This avoids treating truncated or
incompletely forwarded DNSSEC proofs from the Podman bridge resolver as bogus
TLSA data. DANE still fails closed on genuinely invalid DNSSEC signatures.

The HTTP singleton enables HSTS, keeps permissive CORS and untrusted forwarded
addresses disabled, reduces anonymous and authenticated rate limits, and sets a
comprehensive browser security-header baseline. CSP denies resources by
default, blocks frames, plugins, inline scripts, `eval`, and cross-origin API
connections, and narrowly allows the pinned WebUI's same-origin JavaScript,
EventSource, stylesheet, image, and inline-style needs. COEP is intentionally
omitted because enforcing it would break cross-origin resources which do not
opt in; COOP and CORP remain enabled.

The WebDAV singleton explicitly bounds locks, property sizes, request bodies,
and result counts. Assisted discovery stays disabled so standards-compliant
clients discover only resources exposed through normal principal properties;
the public audit verifies the CalDAV, CardDAV, and file-WebDAV routes without
handling user credentials.

The hardening client reads and compares the managed live fields before
applying, so a matching second run performs no server mutation. Its audit then
checks the configuration and outbound TLS selector through Stalwart's API, the
headers and DAV routes on live HTTPS responses, positive TLS 1.3 and negative
TLS 1.2 handshakes on every client endpoint, and a positive TLS 1.2 STARTTLS
handshake on port 25.
It also opens a plaintext SMTP session solely to prove that STARTTLS is
advertised and an unencrypted `MAIL FROM` is rejected.

## Secret Boundary

Two independent SOPS files limit routine secret exposure:

| Scope | Values | Consumers |
| --- | --- | --- |
| Infrastructure | Cloud/DNS administrator credentials and `TOFU_STATE_PASSPHRASE` | Scoped OpenTofu and direct FCOS Rescue children |
| Mail runtime | Database/DNS credentials, backup-provider keys, and independent pgBackRest cipher passphrases | Ansible mail deployment |
| Stalwart hardening | `STALWART_CONFIG_API_TOKEN` | Local pinned Stalwart CLI container |

`SOPS/exec-env.sh` verifies SOPS metadata, clears all known secret names
inherited from the parent, decrypts through a pipe, and exports only the
explicit allowlist for one selected child. Plaintext is not written to a
temporary file or placed in command-line arguments.

Ansible validates runtime secret names and minimum lengths with logging disabled. It
passes values through standard input to `podman secret create` and stores only
the desired SHA-256 hash in a root-only directory to support idempotence.
The Stalwart configuration key is never installed on the server; it is exposed
only to the one local CLI child process. Its Replace-mode permission set covers
only the authentication prerequisite and the declaratively managed system
objects, including `DnsResolver`, plus creation of the immediate
`ReloadSettings` action; the key cannot authenticate to a mail or DAV protocol.

Stalwart's cluster lease identity is explicitly set to the validated, unique
Ansible inventory hostname. This avoids treating Podman's per-container ID as
a new node after every security update, bootstrap deployment, or reconciliation
restart. It does not alter the public mail hostname or certificate identity.

The certificate bootstrap generates a fresh 256-bit recovery password for each
invocation. The server receives `admin:<password>` through SSH standard input
into a randomly named rootful Podman secret which only the temporary Quadlet
maps to `STALWART_RECOVERY_ADMIN`. Direct CLI runtimes receive the password in
the scoped child environment; the Distrobox-to-host bridge uses a separate
transient host-Podman secret because host-spawn does not forward the caller's
environment. The password is never written to SOPS, OpenTofu state, a command
line, or a regular file. On every exit the trap first restores and restarts the
production Quadlet without the recovery environment, then deletes the remote
secret. If that restart fails, it instead preserves and reports the named
server secret because deleting its stored definition would not revoke a value
already injected into the running container. It always removes the local
secret and SSH tunnel; the production reconciliation removes the loopback
publication.
Successful completion additionally requires the operator to create and test a
regular Web UI administrator before the recovery backdoor is revoked.

OpenTofu state contains the generated Stalwart, B2, and Scaleway runtime
credentials. `Scripts/tofu.sh` supplies PBKDF2/SHA-512 key derivation and
enforced AES-GCM state and plan encryption for every Make and CI entry point.
An encrypted state cannot be read by a direct invocation without that
configuration. State is stored in a dedicated, versioned Scaleway bucket with
an S3 lock file. No repository workflow permits plaintext state or plan input.
A `sensitive` output remains a display control, not encryption, so state access
and the passphrase are separate recovery authorities.

Successful applies also stream a state copy directly into SOPS/age encryption
under the repository's ignored `OpenTofu/state-snapshots/` directory. No plaintext snapshot is
written, and these timestamped files are recovery inputs rather than a second
writable backend. They provide recovery from remote-bucket loss but not from
simultaneous loss or compromise of the workstation and its age identity.

## Backup Boundary

PostgreSQL is the authoritative Stalwart configuration, blob, lookup, and mail
data store. pgBackRest continuously archives WAL and creates full and
differential physical backups in two S3-compatible hot repositories. Each uses
AES-256-CBC with a distinct passphrase. A daily logical dump is streamed through
age, signed with an isolated Ed25519 key, and uploaded to all three providers;
no plaintext dump is written to disk.

PostgreSQL uses three distinct identities. The `postgres` administrator owns
server-wide backup controls, `stalwart` is a non-superuser application and
database-owner role, and `stalwart_dump` inherits only `pg_read_all_data` for
logical exports. PostgreSQL startup does not complete until an idempotent gate
has reconciled those roles, including migration of data directories originally
initialized with `stalwart` as the bootstrap superuser. An application SQL
compromise therefore cannot use `COPY PROGRAM`, server-file roles, or
`ALTER SYSTEM` to recover pgBackRest credentials from the database process.

PostgreSQL's B2 credential is confined to `stalwart/pgbackrest/`. Hetzner uses
one project-wide key for both physical and logical backups to keep operation
simple; that dedicated project contains only the mutable hot-backup bucket. A
host compromise can therefore alter or delete the Hetzner copy. The hot
repositories remain availability copies: versioning may preserve older
versions, but a compromised writer can disrupt direct PITR until a trusted
operator selects pre-compromise versions. The separate uploader receives the
shared Hetzner key, prefix-confined B2 and Scaleway credentials, and only the
public verification key; the no-egress dump job receives the database reader
and private signing key but no storage credential. The uploader cannot forge a
candidate by itself, and the signer cannot directly use storage credentials.
The trusted host runner intentionally promotes any valid signer output, so a
signer compromise can create a candidate that the runner publishes. Recovery
therefore requires signature verification with the retained public-key ring and
selection of object versions created before the compromise cutoff. Hot buckets
are versioned and automatic pgBackRest expiry is disabled. The Scaleway identity is confined
to a dedicated project and receives only `ObjectStorageObjectsWrite`; the
Paris bucket adds versioning, compliance object lock, lifecycle expiry, and a
Glacier transition. Within an active Scaleway account, compliance retention
prevents every bucket identity, including organization owners and
administrators, from deleting or shortening retention for locked objects.
Deleting the entire Scaleway account remains a provider-documented exception.
OpenTofu operator credentials can still alter policy for future objects.

The public cold-backup age recipient is safe to deploy. Its private identity and
both pgBackRest passphrases remain offline recovery authorities. Availability
depends on preserving and periodically testing them. Hot retention requires
reviewed operator maintenance and temporary B2 delete permission. The immutable
Scaleway copy, rather than the Hetzner hot copy, is the ransomware boundary.

## DNS Boundary

Host resolution uses the FCOS-provided `systemd-resolved` stub. Its drop-in
routes the DNS root to Cloudflare's `1.1.1.1`, `1.0.0.1`, and corresponding
IPv6 endpoints with the `one.one.one.one` TLS identity. `DNSOverTLS=yes` and
`DNSSEC=yes` fail closed on TLS, certificate, or validation failure. The
fallback list is explicitly empty, while NetworkManager is prevented from
injecting DHCP-provided resolvers into `systemd-resolved`.

Ignition replaces `/etc/resolv.conf` with a link to
`/run/systemd/resolve/stub-resolv.conf`, which sends libc resolver traffic to
the full `127.0.0.53` stub where DNSSEC is validated locally. It deliberately
does not use systemd-resolved's `127.0.0.54` proxy stub, because that endpoint
passes DNS messages through without local DNSSEC validation. The rendered
Ignition regression check enforces this link, strict DNSSEC and DNS-over-TLS,
the empty fallback list, the root route, and the NetworkManager exclusion.

This protects DNS traffic between the VPS and the resolver from passive
observation or modification. It does not hide queries from Cloudflare, and a
Cloudflare or TCP 853 outage makes DNS resolution unavailable rather than
downgrading to plaintext.

OpenTofu reads the existing deSEC zone without owning its lifecycle and owns
only the declared host identity and selected shared records. Stalwart receives
a separate default-deny child token that cannot:

- create or delete domains;
- manage tokens;
- change A or AAAA host records;
- write outside the configured zone;
- authenticate from outside the mail server's declared public addresses.

Every permissive child-token policy has an exact domain, subname, and type.
DKIM selectors and the ACME account are explicit reviewed OpenTofu authority
inputs checked against Stalwart before automatic publication; unrelated names,
wildcard grants, A, and AAAA are absent. TLSA grants are limited to the five exact enabled public
TLS listener names. MX, SPF, TLS-only service discovery, Autodiscover, DMARC,
and TLS-RPT grants are confined to the exact owner/type pairs produced by the
enabled services. CAA remains absent from the child
token and owned by OpenTofu, preventing a compromised Stalwart instance from
redirecting the separate CAA `caa@` destination.
OpenTofu critically denies issuance
at the apex and permits only Stalwart's exact Let's Encrypt account via DNS-01
at `mail`, with an explicit wildcard denial. The `mta-sts`, `autoconfig`,
`autodiscover`, and `ua-auto-config` CNAMEs follow the same CAA exception.

## Supply-Chain Boundary

- GitHub Actions use full commit pins.
- Stalwart, its management CLI, and PostgreSQL use a readable version tag plus
  immutable image digest.
- Butane and coreos-installer run only from exact tag-and-digest pins in
  `Tools/compose.yaml`; no PATH-resolved fallback exists. The direct installer
  transfers coreos-installer with the runtime libraries from that same
  immutable image and invokes its bundled loader, avoiding an unpinned Rescue
  package installation.
- CI verifies the Stalwart server and CLI exact tag-workflow identities,
  keyless signatures, Rekor inclusion, and SLSA provenance before accepting
  their digests.
- OpenTofu providers use version constraints and a multi-platform checksum
  lockfile.
- CI's Python validation environment is fully locked, hash-checked, and
  wheel-only.
- Ansible verifies the pinned Web UI SHA-256 before atomic installation;
  Stalwart reads it from a read-only `file://` mount, and live audits reject
  Application drift.
- gVisor uses an immutable release path and pinned SHA-512 digest.
- Dependabot delays action, Python, and both application and tool-container
  proposals for seven days, providing a short observation window before
  review.

Pins prevent unexpected mutation; they do not replace release-note review,
vulnerability monitoring, provenance checks, or rollback planning.
PostgreSQL remains a documented digest-only exception because its official
image does not currently publish equivalent Sigstore evidence.

## Residual Risks

- The service is a single node and has no automatic failover.
- gVisor adds material I/O and networking overhead to PostgreSQL and Stalwart.
- gVisor does not accept Podman's SELinux process label, so these two workloads
  do not receive SELinux MCS separation; their container boundary relies on
  gVisor, namespaces, read-only roots, and explicit mounts instead.
- PostgreSQL traffic is unencrypted inside the dedicated internal container
  network on one host. Isolation relies on Podman, gVisor, and host integrity.
- Hetzner VM snapshots remain crash-consistent secondary recovery aids, not the
  application-consistent PostgreSQL backup boundary.
- Hot pgBackRest repositories grow until trusted operator-side expiry runs;
  only the generated B2 runtime key is technically prevented from deleting.
- Restore drills and offline recovery-key custody remain operational duties;
  the repository does not automatically prove that a backup can be restored.
- Stalwart listener, HTTP, authentication, protocol limits, SMTP throttles,
  queue quota, SMTP-auth, outbound TLS, inbound report analysis, Domain, DNS,
  DKIM, and certificate
  settings are declarative; account lifecycle, mailbox policy, deliverability, and
  reputation controls still require application-level administration.
- The reviewed controller-authority input contains the public ACME account URI
  and must be updated explicitly before an ACME provider is replaced. The apex
  CAA policy critically denies TLS, wildcard, S/MIME, and
  BIMI mark-certificate issuance; the `mail` exception remains TLS-only and
  account/method-bound. Stalwart cannot change CAA with its child token; all of
  its mail-DNS access is confined to reviewed owner/type pairs.
- While the automated bootstrap is running, its loopback-only Stalwart endpoint
  is reachable solely through an authenticated SSH local forward restricted to
  `127.0.0.1:8080`. Enrolled systems map that temporary host port to the
  hostname-validated TLS listener on 443; only first enrollment maps it to the
  initial cleartext listener. The exit trap restores the production Quadlet on
  success or failure.
- The host has no explicit outbound firewall allowlist.
- Requiring three authenticated NTS sources improves time integrity but can
  leave the clock unsynchronized during a broad NTS outage.
- Strict Cloudflare DNS-over-TLS centralizes host DNS visibility at Cloudflare
  and deliberately fails closed if every endpoint or TCP port 853 is
  unavailable.
- gVisor must be downloaded from Google storage during first boot; a network or
  upstream outage prevents the mail containers from starting.
- Provider compromise, malicious reviewed dependencies, operator compromise,
  and FCOS host-root compromise remain outside the protection gVisor provides.
- Losing every matching SOPS or cold-backup age identity, the OpenTofu state
  passphrase, or a pgBackRest repository passphrase makes the corresponding
  encrypted material unrecoverable.

## Security Changes

Changes to authentication, firewall exposure, DNS authority, SOPS recipients,
container runtime flags, volume mounts, or OpenTofu state storage should be
reviewed as trust-boundary changes rather than routine configuration edits.

Report repository-specific vulnerabilities according to the
[security policy](../SECURITY.md).
