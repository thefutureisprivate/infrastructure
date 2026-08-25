<h1 align="center">Infrastructure</h1>

<p align="center">
  A minimal and hardened infrastructure stack for Hetzner Cloud.
</p>

<p align="center">
  <strong>Fedora CoreOS, Stalwart, PostgreSQL, gVisor, OpenTofu, Ansible, and SOPS/age.</strong>
</p>

## Table of Contents

- [Purpose](#purpose)
- [Architecture](#architecture)
- [Features](#features)
- [Security and Hardening](#security-and-hardening)
- [Dependencies](#dependencies)
- [Deploy](#deploy)
- [Diagnostics and Tests](#diagnostics-and-tests)
- [Documentation](#documentation)

## Purpose

This repository provisions reusable hardened Fedora CoreOS VPS nodes on
Hetzner Cloud and assigns one node the Stalwart/PostgreSQL mail role. The
current production shape uses an x86_64 CX23 for that role. OpenTofu owns the
cloud and DNS resources, and Ansible reconciles rootful Podman Quadlets without
requiring Python on the servers.

The goal is a small, understandable system with explicit ownership. Every VPS
receives the same mail-independent Ignition and base firewall; only the
selected mail node receives mail ingress and the mail Ansible role. OpenTofu
manages infrastructure records, Stalwart is authorized to manage only the mail
records it can maintain natively, secrets remain encrypted with SOPS and age,
and application containers run behind the gVisor userspace kernel.

## Architecture

The deployment is split into narrow layers:

| Layer | Responsibility |
| --- | --- |
| Butane and Ignition | Reusable FCOS user, SSH, host hardening, and checksum-pinned gVisor baseline |
| OpenTofu | Hetzner VPS fleet, base and role firewalls, per-node forward/reverse DNS, and the restricted Stalwart token |
| SOPS and age | Encrypted provider and application secret scopes |
| Ansible | Python-free reconciliation of Podman secrets, support files, networks, volumes, and Quadlets |
| Quadlet | Declarative systemd lifecycle for Stalwart and PostgreSQL |
| Stalwart plan | Idempotent listener, HTTP-header, CSP, rate-limit, and SMTP-auth policy |

Ignition is sent directly as Hetzner user data on first boot; cloud-init is not
part of the design. OpenTofu outputs the generated Ansible inventory, so the
same declared server identity flows into DNS, reverse DNS, and the mail
deployment. The full lifecycle and trust boundaries are documented in
[Architecture](Documentation/Architecture.md).

## Features

- Uploads the current Fedora CoreOS Hetzner image as a labeled snapshot.
- Provisions one or more equally hardened FCOS nodes with a shared SSH/ICMP
  firewall, mail ingress attached only to the selected mail node, and an
  optional spread placement group.
- Reads the existing deSEC zone, declaratively imports the selected shared
  RRsets, manages per-node A/AAAA and Hetzner PTR records, and exposes its
  DNSSEC material for verification.
- Mints a default-deny deSEC child token for Stalwart, restricted by zone,
  record type, and mail-server source address.
- Deploys digest-pinned Stalwart and PostgreSQL images as rootful Quadlets.
- Runs both containers with `runsc` and refuses to start them before the
  checksum-pinned gVisor bundle is installed.
- Sends host DNS exclusively through systemd-resolved's full local validating
  stub and authenticated Cloudflare DNS-over-TLS, with strict DNSSEC and no
  plaintext or non-validating fallback.
- Keeps PostgreSQL off the host network and publishes only SMTP,
  HTTPS/JMAP/CalDAV/CardDAV/WebDAV, implicit-TLS submission, and IMAPS. The temporary bootstrap listener is
  opt-in and bound to loopback only.
- Reconciles the exact production listeners, permits password authentication
  only after TLS is active, disables permissive CORS and forwarded-IP trust,
  and applies HSTS, CSP, anti-framing, no-sniff, referrer, permissions, origin,
  and cache-control response headers.
- Validates Butane, OpenTofu, YAML, Ansible, shell sources, Stalwart's
  Sigstore provenance, and a zero-change second Ansible run in CI.
- Pins GitHub Actions to commits and container images to digests; Dependabot
  observes a seven-day cooldown before proposing updates.

## Security and Hardening

Security controls are applied at every layer:

- **Host:** reusable FCOS kernel policy and administrator drop-ins for sysctl,
  modules, authenticated NTS time, bounded persistent logs, core dumps, SSH,
  encrypted DNS, and containers, plus masked debug services, SELinux, and an
  immutable OS base.
- **SSH:** public-key authentication only, no root login, no password or
  keyboard-interactive authentication, no agent, remote, or arbitrary local
  forwarding, and no automatically generated non-TCP listeners. The sole local
  forwarding destination is the loopback Stalwart bootstrap listener. Port 22
  remains reachable from every address by design.
- **Containers:** gVisor `runsc`, read-only root filesystems, bounded temporary
  filesystems, private networking, PostgreSQL no-new-privileges, and
  systemd-managed restart ordering.
- **Stalwart:** client protocols use implicit TLS only; SMTP port 25 remains a
  non-authenticated federation listener with mandatory STARTTLS before message
  transfer. HTTPS, submission, and IMAPS require TLS 1.3; SMTP federation
  retains TLS 1.2 compatibility.
  CalDAV, CardDAV, and WebDAV share the hardened HTTPS listener and have
  explicit resource bounds. A declarative plan removes POP3, ManageSieve,
  cleartext HTTP, and STARTTLS client listeners.
- **Secrets:** separate encrypted provider and mail scopes; decrypted values
  enter only the child process that needs them. Ansible creates Podman secrets
  over standard input and renders no credentials into Quadlets.
- **DNS:** the deSEC account retains zone lifecycle authority; OpenTofu owns the
  selected shared RRsets, token, A/AAAA, PTR, and CAA declarations. Stalwart's
  child token grants only reviewed owner-name/type pairs and exact DKIM
  selectors; it has no zone-wide or TLSA authority.
- **Supply chain:** provider locks, action commit pins, image digests, verified
  Stalwart server and CLI signatures and SLSA provenance, hash-locked CI tools,
  digest-pinned provisioning containers, a checksum-verified local Web UI, and
  a SHA-512-pinned gVisor release bundle.

The design deliberately trades some database and network performance for
gVisor isolation. It is a single-node deployment, not a high-availability mail
cluster. See [Security Model](Documentation/Security.md) for assumptions,
residual risks, and secret boundaries.

## Dependencies

| Dependency | Use |
| --- | --- |
| OpenTofu 1.12.6 | Cloud, DNS, reverse-DNS, and scoped-token state |
| SOPS and age | Local encryption and decryption of secret scopes |
| Ansible Core 2.20 | Python-free remote Quadlet reconciliation |
| Podman or Docker | Run the repository-pinned Butane, coreos-installer, hcloud uploader, and Stalwart CLI images |
| jq, curl, OpenSSL, GNU coreutils, GNU Make, Bash, and OpenSSH | Local orchestration, audits, and inventory handling |

The target host needs no manually installed configuration runtime. Fedora
CoreOS supplies systemd, Podman, and the Quadlet generator; Ignition installs
the pinned gVisor bundle during first boot.

## Deploy

Prepare the encrypted credentials and deployment variables:

```bash
make sops-infrastructure-edit
make sops-mail-edit
cp OpenTofu/terraform.tfvars.example OpenTofu/terraform.tfvars
```

Upload FCOS, initialize OpenTofu, create and apply a reviewed plan, then render
the inventory:

```bash
make image
make tofu-init
make plan
make apply
make inventory
```

Verify the server's SSH host key through an independent channel and store it in
`Ansible/inventory/known_hosts`. Bootstrap Stalwart, complete its domain and
certificate setup, save the scoped configuration API key in SOPS, then apply
the hardening plan and remove the bootstrap publication:

```bash
make deploy-bootstrap
make sops-mail-edit
make stalwart-harden
make deploy
make stalwart-audit
```

The image upload creates temporary billable Hetzner resources. Ignition runs
only on first boot, so changing host hardening or the gVisor pin requires a
server rebuild. Follow [Deployment](Documentation/Deployment.md) for the full
procedure, DNSSEC verification, host-key verification, and the exact
[Stalwart production setup](Documentation/Stalwart.md).

## Diagnostics and Tests

Run all locally available static checks:

```bash
make check
```

Inspect the deployed services on the FCOS host:

```bash
sudo systemctl status gvisor-install.service mail-postgres.service mail-stalwart.service
sudo journalctl -u gvisor-install.service -u mail-postgres.service -u mail-stalwart.service
sudo podman ps
```

`make check` compiles a test Ignition document and enforces Hetzner's 32 KiB
user-data limit. CI additionally initializes and validates OpenTofu from the
committed provider lock file. Operational checks, upgrades, and recovery
guidance live in [Operations](Documentation/Operations.md).

## Documentation

- [Documentation index](Documentation/README.md)
- [Architecture](Documentation/Architecture.md)
- [DNS Ownership](Documentation/DNS.md)
- [Deployment](Documentation/Deployment.md)
- [Operations](Documentation/Operations.md)
- [Stalwart Production Setup](Documentation/Stalwart.md)
- [Security Model](Documentation/Security.md)
