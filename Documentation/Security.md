# Security Model

## Security Objective

The stack aims to reduce the probability and impact of compromise across four
boundaries: the operator workstation, infrastructure providers, the FCOS host,
and the mail containers. No single control is treated as sufficient.

The primary protected assets are:

- mail data and PostgreSQL contents;
- Stalwart administrator and user credentials;
- Hetzner and deSEC provider authority;
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
- SELinux labeling for host and container-mounted files.

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

## Container Boundary

Both Stalwart and PostgreSQL use the explicitly registered `runsc` OCI runtime.
The containers require `gvisor-install.service`, so a missing or failed runtime
installation blocks application startup rather than silently falling back to
the default runtime.

The installer:

- uses an immutable release URL rather than `latest`;
- requires HTTPS with TLS 1.2 or newer;
- retries transient failures without accepting HTTP errors;
- verifies a pinned SHA-512 digest before extraction;
- requires the new multi-file bundle layout and adjacent sidecars;
- preserves SELinux rather than disabling container labels globally;
- runs as a hardened one-shot systemd unit with a read-only filesystem except
  for its explicit installation paths.

Both Quadlets add read-only roots, bounded tmpfs mounts, named persistent
volumes, and a private network. PostgreSQL also sets no-new-privileges and has
no published host port. Stalwart runs as the image's unprivileged UID 2000 and
retains the image capability needed to bind privileged mail ports. It publishes
only the services selected in OpenTofu variables. Its bootstrap HTTP publication
is disabled by default and can be enabled only on host loopback for initial
setup.

## Stalwart Boundary

The production plan reconciles the listener collection rather than merely
adding preferred listeners. Only federated SMTP on 25, HTTPS/JMAP/admin on 443,
implicit-TLS submission on 465, and IMAPS on 993 survive reconciliation. POP3,
ManageSieve, cleartext HTTP, and STARTTLS client ports 143 and 587 are removed.
SMTP port 25 remains non-implicit for Internet federation, but AUTH is disabled
on that port; SMTP client authentication of every kind is offered only when
TLS is already active on a non-federation listener.

The HTTP singleton enables HSTS, keeps permissive CORS and untrusted forwarded
addresses disabled, reduces anonymous and authenticated rate limits, and sets a
comprehensive browser security-header baseline. CSP denies resources by
default, blocks frames, plugins, inline scripts, `eval`, and cross-origin API
connections, and narrowly allows the pinned WebUI's same-origin JavaScript,
EventSource, stylesheet, image, and inline-style needs. COEP is intentionally
omitted because enforcing it would break cross-origin resources which do not
opt in; COOP and CORP remain enabled.

The hardening client reads and compares the managed live fields before
applying, so a matching second run performs no server mutation. Its audit then
checks the configuration through Stalwart's API, the headers on a live HTTPS
response, and certificate validation on ports 465 and 993.

## Secret Boundary

Two independent SOPS files limit routine secret exposure:

| Scope | Values | Consumers |
| --- | --- | --- |
| Infrastructure | `HCLOUD_TOKEN`, bootstrap `DESEC_API_TOKEN` | OpenTofu and FCOS image uploader |
| Mail runtime | `MAIL_POSTGRES_PASSWORD`, restricted `STALWART_DESEC_API_TOKEN` | Ansible mail deployment |
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
only the authentication prerequisite and the NetworkListener, Application,
Http, and MtaStageAuth objects; the key cannot authenticate to a mail protocol.

OpenTofu state still contains the generated Stalwart token. A `sensitive`
output hides normal CLI display but does not encrypt state. Local ignored state
is acceptable only while the workstation is adequately protected; shared CI
or multi-operator use requires an encrypted, access-controlled remote backend.

## DNS Boundary

Host resolution uses the FCOS-provided `systemd-resolved` stub. Its drop-in
routes the DNS root to Cloudflare's `1.1.1.1`, `1.0.0.1`, and corresponding
IPv6 endpoints with the `one.one.one.one` TLS identity. `DNSOverTLS=yes` and
`DNSSEC=yes` fail closed on TLS, certificate, or validation failure. The
fallback list is explicitly empty, while NetworkManager is prevented from
injecting DHCP-provided resolvers into `systemd-resolved`.

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
DKIM selectors are explicit OpenTofu inputs; unrelated names, wildcard grants,
TLSA, CAA, A, and AAAA are absent. OpenTofu's apex CAA denies ordinary and
wildcard issuance. A more-specific CAA at `mail` authorizes ordinary issuance
only to Stalwart's exact Let's Encrypt account using DNS-01 and keeps wildcard
issuance denied.

## Supply-Chain Boundary

- GitHub Actions use full commit pins.
- Stalwart, its management CLI, and PostgreSQL use a readable version tag plus
  immutable image digest.
- Butane, coreos-installer, and hcloud-upload-image run only from exact
  tag-and-digest pins in `Tools/compose.yaml`; no PATH-resolved fallback exists.
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
- PostgreSQL traffic is unencrypted inside the private container network on one
  host. Isolation relies on Podman, gVisor, and host integrity.
- Hetzner backups are not guaranteed to be application-consistent PostgreSQL
  backups.
- Stalwart listener, HTTP, and SMTP-auth hardening is declarative; domain,
  certificate, account lifecycle, mail policy, and reputation controls still
  require application-level administration.
- The Stalwart Quadlet does not currently set no-new-privileges; its upstream
  image uses a file capability to bind ports below 1024 as UID 2000.
- When explicitly enabled, the loopback-only Stalwart bootstrap is reachable
  only through an authenticated SSH local forward restricted to
  `127.0.0.1:8080`; the listener and publication are removed during production
  hardening.
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
- Losing every matching age private identity makes the encrypted secrets
  unrecoverable.

## Security Changes

Changes to authentication, firewall exposure, DNS authority, SOPS recipients,
container runtime flags, volume mounts, or OpenTofu state storage should be
reviewed as trust-boundary changes rather than routine configuration edits.

Report repository-specific vulnerabilities according to the
[security policy](../SECURITY.md).
