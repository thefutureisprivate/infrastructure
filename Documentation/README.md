# Documentation

This directory contains the design and operating documentation for the
infrastructure repository.

## Guides

- [Architecture](Architecture.md) explains component ownership, data flow,
  runtime layout, and persistent state.
- [DNS Ownership](DNS.md) records the imported deSEC zone, ownership split,
  OpenTofu-managed ACME CAA policy, and read-only zone-audit procedure.
- [Deployment](Deployment.md) covers a first deployment from credentials to a
  running Quadlet stack.
- [Operations](Operations.md) covers routine reconciliation, diagnostics,
  upgrades, backups, and recovery.
- [Silverblue Workstation](Silverblue.md) covers local staged OS updates,
  explicit package layering, host hardening, and per-user Flatpak reconciliation.
- [Stalwart Production Setup](Stalwart.md) records the production identity,
  secure bootstrap tunnel, DNS/ACME settings, listeners, and Web UI workflow.
- [Security Model](Security.md) records trust assumptions, layered controls,
  secret boundaries, and residual risks.

Start with [Deployment](Deployment.md) when building a new environment. Read
[Architecture](Architecture.md) and [Security Model](Security.md) before
changing ownership boundaries, network exposure, secret handling, or the
gVisor runtime.
