# Operations

## Routine Reconciliation

Use saved OpenTofu plans for cloud and DNS changes:

```bash
make plan
make apply
make inventory
```

Re-run Ansible after changes to container pins, Quadlets, support files, or
mail secrets:

```bash
make deploy
```

The current playbook targets only the `mail` inventory group. Ansible compares
desired content before replacing files and restarts only affected services.
Removal is never inferred: retiring a Quadlet requires an explicit entry in
`quadlet_absent_units`.

Reconciliation is tested with two consecutive runs in CI. The second run must
report `changed=0` and must not perform hidden Podman-secret or systemd
mutations. Duplicate destinations, desired/absent conflicts, unmanaged service
dependencies, and file-metadata drift are handled explicitly by the role.

Run validation before either workflow:

```bash
make check
```

Reconcile and audit Stalwart's managed application settings after certificate
bootstrap or a reviewed change to `Stalwart/hardening.ndjson`:

```bash
make stalwart-harden
make stalwart-audit
```

The first target compares the live managed fields and skips the apply when
there is no drift. The audit is read-only: it verifies the exact listener,
HTTP, WebDAV, SMTP-auth, and MAIL-stage settings, checks all configured security
headers and the CalDAV, CardDAV, and WebDAV routes over live HTTPS, requires TLS
1.3 on ports 443, 465, and 993, and verifies TLS 1.2 STARTTLS compatibility on
the SMTP federation listener. It also fails if that listener accepts an
unencrypted `MAIL FROM`, if any extra Stalwart listener exists, or if a client
listener accepts TLS 1.2.

## Service Diagnostics

Check systemd state and recent logs:

```bash
sudo systemctl status gvisor-install.service mail-postgres.service mail-stalwart.service
sudo journalctl -b -u gvisor-install.service
sudo journalctl -b -u mail-postgres.service
sudo journalctl -b -u mail-stalwart.service
```

Inspect containers and health:

```bash
sudo podman ps --all
sudo podman inspect --format '{{.OCIRuntime}} {{.State.Status}} {{.State.Health.Status}}' mail-postgres
sudo podman inspect --format '{{.OCIRuntime}} {{.State.Status}}' mail-stalwart
sudo /usr/local/bin/runsc --version
```

Inspect generated unit definitions when Quadlet startup fails:

```bash
sudo systemctl cat mail-postgres.service
sudo systemctl cat mail-stalwart.service
sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun
```

Check DNS and OpenTofu's declared identity:

```bash
tofu -chdir=OpenTofu output dns_records
tofu -chdir=OpenTofu output mail_dns
dig A MAIL_HOSTNAME
dig AAAA MAIL_HOSTNAME
dig -x SERVER_ADDRESS
```

## Container Updates

`Ansible/compose.yaml` is a dependency lockfile, not the deployment mechanism.
Dependabot reads it as Docker Compose input and proposes digest-pinned Stalwart
server, Stalwart CLI, and PostgreSQL updates after a seven-day cooldown.

For each update:

1. Review the upstream release notes and database migration requirements.
2. Confirm that the human-readable tag and immutable digest identify the
   intended release.
3. Run `make check`; this validates every image reference without requiring
   network access.
4. Review a backup and rollback plan, especially for PostgreSQL major updates.
5. Let CI verify the Stalwart server and CLI digests against their exact GitHub
   tag workflows, Rekor entries, and SLSA provenance. PostgreSQL is
   intentionally reported as a digest-only exception because the upstream
   image is not signed.
6. Run `make deploy` and watch both service journals.

`Pull=missing` is safe with digest changes: Podman pulls the new immutable image
when that digest is absent. Do not replace digest pins with mutable tags.

Run the network-backed provenance check locally when Cosign is installed:

```bash
./Scripts/verify-container-provenance.sh
```

## GitHub Actions and Provider Updates

GitHub Actions are pinned to full commit hashes in the workflow. Dependabot
proposes updates after the same seven-day cooldown. Preserve the full hash and
the adjacent release comment when reviewing a change.

OpenTofu providers are constrained in `OpenTofu/versions.tf` and fully hashed
in `OpenTofu/.terraform.lock.hcl`. Review provider changelogs, run
`tofu -chdir=OpenTofu init -upgrade` intentionally, inspect the lockfile diff,
and validate a saved plan before applying.

## gVisor Updates

gVisor is installed by Ignition rather than a package manager. Its release and
SHA-512 pin live in `Butane/files/install-gvisor.sh`.

To update it:

1. Select a production release using the official
   [gVisor installation guide](https://gvisor.dev/docs/user_guide/install/).
2. Use the multi-file `gvisor.tar.bz2` artifact for x86_64.
3. Verify the publisher's `.sha512` file and the downloaded archive.
4. Update both `version` and `archive_sha512` together.
5. Confirm the archive contains executable `runsc`, executable
   `containerd-shim-runsc-v1`, and the adjacent `gvisor-bin/` directory.
6. Run `make check` and rebuild the FCOS server.

The marker on the host makes installation idempotent, but Ignition does not
reconcile an existing machine. A repository pin change alone cannot upgrade a
running host.

## Fedora CoreOS Updates

FCOS owns its operating-system update lifecycle. Monitor Zincati and the active
deployment on the host:

```bash
systemctl status zincati.service
rpm-ostree status
```

Test application startup after an OS update and reboot. Kernel arguments and
Ignition-created files remain part of the installed machine, but new
repository changes still require a rebuild or a separately designed
reconciliation path.

## Host Hardening Checks

After a rebuild, verify that the compatibility-first hardening controls did not
disturb the required runtime paths:

```bash
sudo sshd -T | grep -E 'allowusers|logingracetime|maxauthtries|maxsessions'
systemctl is-enabled sshd-vsock.socket sshd-unix-local.socket
sudo sysctl kernel.panic kernel.panic_on_oops kernel.yama.ptrace_scope vm.mmap_rnd_bits
chronyc -N authdata
chronyc sources -v
readlink -f /etc/resolv.conf
resolvectl status
resolvectl query cloudflare.com
journalctl -b -u systemd-resolved.service
journalctl --disk-usage
systemctl status zincati.service
```

At least three authenticated chrony sources must remain usable. The two SSH
socket units should report `masked`; `resolvectl status` must show only the four
Cloudflare endpoints with DNS-over-TLS and DNSSEC enabled; and Zincati must
remain active. `readlink` must return
`/run/systemd/resolve/stub-resolv.conf`, and the successful query must report
that its answer is authenticated. A query for a deliberately broken DNSSEC
test domain must fail rather than return an address:

```bash
if resolvectl query dnssec-failed.org; then
  printf 'DNSSEC validation unexpectedly accepted a bogus answer\n' >&2
  exit 1
fi
```

On the mail-role node, additionally verify both containers still use `runsc`:

```bash
sudo podman inspect --format '{{.OCIRuntime}}' mail-postgres mail-stalwart
```

A failure in any applicable check blocks a production cutover.

## Secret Rotation

Provider credentials can be replaced by editing the encrypted infrastructure
scope:

```bash
make sops-infrastructure-edit
```

Revoke the old token at its provider after the new token has been tested.

Mail secrets are edited with:

```bash
make sops-mail-edit
```

Then run `make deploy`. Ansible stops dependent services, replaces the Podman
secret, records only its SHA-256 hash, and restarts the stack.

Changing `MAIL_POSTGRES_PASSWORD` is not, by itself, a complete PostgreSQL
credential rotation. The official PostgreSQL image applies
`POSTGRES_PASSWORD` only while initializing an empty data directory. Coordinate
an explicit database-role password change with the SOPS update and Stalwart
restart; otherwise Stalwart will lose database access.

The Stalwart deSEC token is created by OpenTofu. When it is deliberately
replaced, apply the reviewed infrastructure plan and let `make apply` sync the
new value into the encrypted mail scope before running `make deploy`. Revoke
the old child token only after the new credential is working.

Rotate `STALWART_CONFIG_API_TOKEN` independently in the Stalwart account
portal. Create a replacement with the exact Replace-mode permission set in
`Documentation/Stalwart.md`, store its one-time value with
`make sops-mail-edit`, run `make stalwart-audit`, and only then revoke the old
key. Restrict its allowed source addresses when the operator has stable public
egress CIDRs.

## Backups and Recovery

Hetzner backups are enabled by default, but a virtual-machine snapshot is not a
substitute for an application-consistent PostgreSQL backup. The repository does
not currently automate `pg_dump`, off-site retention, restore testing, or
Stalwart data export.

Before production use, define and test:

- encrypted, off-host PostgreSQL backups;
- backup coverage for the Stalwart named volume;
- OpenTofu state backup or an encrypted remote backend;
- secure backup of the age private identity;
- recovery of `Ansible/inventory/known_hosts` after a verified rebuild;
- restore procedures and recovery-time objectives.

Never copy PostgreSQL's live volume as though it were a consistent database
backup. Use PostgreSQL-aware backup and restore tooling.

## Rebuilds

Rebuild the server when Butane, Ignition, kernel arguments, SSH policy, or the
gVisor pin changes. A rebuild changes the SSH host key and may replace public
addresses depending on the OpenTofu operation.

Before rebuilding:

1. Verify current application-consistent backups and a restore test.
2. Review DNS TTLs, expected addresses, and mail-delivery impact.
3. Preserve protected OpenTofu state and the age identity.
4. Create and review an OpenTofu plan rather than making console-only changes.
5. Apply the replacement, then run `make fcos-install`; the new server starts
   with a `pending` marker and is installed directly through Rescue.
6. Re-establish SSH host-key trust through an independent channel.

Delete protection and rebuild protection are enabled by default. Do not disable
them casually or bypass the reviewed infrastructure lifecycle.

`FCOS_REINSTALL=1 make fcos-install` deliberately overwrites the existing
server disk even when its marker is `installed`. It is intended only for a
reviewed in-place reprovision after backups and should not replace the normal
OpenTofu replacement workflow.
