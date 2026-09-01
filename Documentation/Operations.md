# Operations

## Routine Reconciliation

Use saved OpenTofu plans for cloud and DNS changes:

```bash
make plan
make apply
make inventory
```

The remote S3 backend is the single authoritative state. `make apply`
automatically writes a timestamped SOPS/age-encrypted recovery snapshot to the
git-ignored `OpenTofu/state-snapshots/` directory immediately after the
OpenTofu apply succeeds and before generated credentials are synchronized. A
credential-synchronization failure therefore still leaves a current recovery
snapshot. Run the snapshot explicitly after a manual import or direct state
operation:

```bash
make tofu-state-snapshot
```

The local files are immutable recovery inputs rather than a second backend, so
there is no split-brain synchronization path. They contain state secrets and
must remain encrypted. To restore one after confirmed loss of the remote
state, first recreate and initialize the empty backend, then restore one exact
reviewed snapshot through the pipe-only restore target:

```bash
make tofu-state-restore \
  TOFU_STATE_SNAPSHOT=OpenTofu/state-snapshots/infrastructure-<timestamp>.sops.json
```

The target accepts only regular files inside the dedicated snapshot directory,
validates full SOPS encryption before decryption, validates the state envelope,
and does not use OpenTofu's destructive `-force` option.

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
HTTP, WebDAV, SMTP-auth, MAIL-stage, and outbound TLS strategy settings. It
checks all configured security headers and the CalDAV, CardDAV, and WebDAV
routes over live HTTPS, requires TLS 1.3 on ports 443, 465, and 993, and verifies
TLS 1.2 STARTTLS compatibility on the SMTP federation listener. It also fails
if outbound delivery can select the invalid-certificate strategy, if that
listener accepts an unencrypted `MAIL FROM`, if any extra Stalwart listener
exists, or if a client listener accepts TLS 1.2.

Run the idempotent DNS and certificate bootstrap after rebuilding Stalwart,
replacing its ACME account, or creating a new automatic DKIM selector:

```bash
make stalwart-bootstrap
```

It temporarily publishes loopback-only recovery access, using Stalwart's
hostname-validated TLS listener when already enrolled and its initial HTTP
listener only during first enrollment. It synchronizes the exact current DKIM
selectors against the reviewed OpenTofu authority file,
reconciles production DNS-01 ACME, and resumes staging whenever the managed
Domain carries the persistent `staged enrollment pending` marker. It verifies
public trust and
always restores the production Quadlet. It uses an ephemeral recovery
credential and does not store it.

Stalwart's cluster-node lease is pinned to the Ansible inventory hostname both
as the container's operating-system hostname and through `STALWART_HOSTNAME`.
This also keeps recovery-mode deployments from registering transient Podman
container IDs. The stable identity is declarative, so routine reconciliation
requires no separate cluster-registry audit or cleanup command.

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

The shared `hetzner_ipv6` role and first-boot Ignition unit obtain each
server's static IPv6 address, prefix, gateway, and interface MAC from Hetzner's
link-local metadata service. They update only the matching NetworkManager
connection and ignore metadata DNS servers so systemd-resolved retains the
DNSSEC-validating Cloudflare DNS-over-TLS policy.

Inspect generated unit definitions when Quadlet startup fails:

```bash
sudo systemctl cat mail-postgres.service
sudo systemctl cat mail-stalwart.service
sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun
```

Check DNS and OpenTofu's declared identity:

```bash
make tofu-output
dig A MAIL_HOSTNAME
dig AAAA MAIL_HOSTNAME
dig -x SERVER_ADDRESS
```

## Container Updates

`Ansible/compose.yaml` is a dependency lockfile, not the deployment mechanism.
Dependabot reads it as Docker Compose input and proposes digest-pinned Stalwart
server, Stalwart CLI, and PostgreSQL updates after a seven-day cooldown.
The Stalwart server pin deliberately selects the upstream Alpine/musl variant;
the offline image-policy check rejects a switch back to the default runtime.

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
`make tofu-upgrade` intentionally, inspect the lockfile diff, and validate a
saved plan before applying.

## gVisor Updates

gVisor is installed by Ignition rather than a package manager. Its release and
SHA-512 pin live in `Butane/files/install-gvisor.sh`.
The installer extracts the archive's top-level binaries and its `gvisor-bin`
sidecars in separate passes. This keeps the service's
`RestrictSUIDSGID=yes` sandbox enabled while avoiding GNU tar's nested-path
`openat2` incompatibility with that restriction on FCOS.
The installer verifies the archive and every expected executable. The direct
FCOS controller then runs `runsc --version` after boot, outside the install
unit's intentionally PID-only `/proc`, before a strict permanent-host-key
verification marks the node installed.

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

The PostgreSQL start gate reconciles the distinct
`MAIL_POSTGRES_ADMIN_PASSWORD`, `MAIL_POSTGRES_PASSWORD`, and
`MAIL_POSTGRES_DUMP_PASSWORD` values on every container start. Rotate one or
more values together in SOPS and run `make deploy`; Stalwart starts only after
the administrator, non-superuser application, and read-only dump roles have
the declared passwords and privilege flags.

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

Keep `mail_backup_storage_enabled = true` for the lifetime of retained backup
data. `mail_backup_enabled` independently controls runtime policies,
credentials, inventory, secrets, and schedules. Setting only the runtime flag
false pauses backups and revokes runtime access without planning destruction of
the protected buckets.

When both flags are true, the mail host maintains three independent,
application-consistent PostgreSQL copies:

| Copy | Schedule | Encryption | Retention boundary |
| --- | --- | --- | --- |
| Hetzner Object Storage | Physical pgBackRest plus daily signed logical archive | Independent pgBackRest encryption; age + Ed25519 for logical archives | Versioned mutable hot bucket in a dedicated project with one shared credential pair |
| Backblaze B2 | Physical pgBackRest plus daily signed logical archive | Independent pgBackRest encryption; age + Ed25519 for logical archives | Separate prefix-confined keys; signed writer cannot list or read archives |
| Scaleway Object Storage/Glacier (Paris) | Daily signed logical archive | Streaming age encryption plus Ed25519 manifest signature | Compliance object lock, versioning, Glacier transition after 90 days, expiry after the declared retention period |

The generated Scaleway runtime API key expires and rotates annually to satisfy
the organization security policy. A plan that replaces this key must be
applied immediately before `make inventory && make deploy`: `make apply`
synchronizes the new one-time secret into SOPS, and deployment installs it on
the mail host. Do not leave a completed key-rotation apply undeployed.

Within an active Scaleway account, compliance retention cannot be bypassed by
the runtime identity, OpenTofu credentials, or organization administrators.
Locked objects cannot be deleted and their retention cannot be shortened before
the declared period expires; lifecycle expiry becomes effective only after that
boundary. Scaleway documents deletion of the entire account as the exceptional
way to remove retained objects early.

The 05:00 UTC check timer validates both pgBackRest repositories and WAL
archiving. All timers are persistent and use a stable randomized delay. A
shared host-kernel lock queues physical, logical, and check operations for up
to six hours and fails visibly on timeout. The host holds that lock across the
complete gVisor logical job. The logical path never creates a plaintext dump:
the no-egress signer streams `pg_dump` through age, signs a manifest binding
the digest, size, and all three destinations, and a separate uploader verifies
that signature before publishing it last as the restore commit marker. Failed
creation removes its incomplete active files; structurally invalid or tampered
staging is moved under the protected `failed/` quarantine so a later scheduled
backup can proceed without discarding the evidence.

This split prevents an uploader-only compromise from forging a manifest, but
the trusted host runner automatically publishes valid signer output. Treat a
signer compromise as authority to inject candidates, and select a retained
object version from before the incident cutoff during recovery.

Inspect the schedule and most recent results on the mail host:

```bash
sudo systemctl list-timers 'mail-pgbackrest-*' mail-backup-logical.timer
sudo systemctl status mail-pgbackrest-init.service
sudo journalctl -u 'mail-pgbackrest-*' -u mail-backup-logical-run.service --since '7 days ago'
sudo systemctl start mail-pgbackrest-check.service
sudo podman exec --user 70 mail-postgres \
  pgbackrest --stanza=stalwart --repo=1 info
sudo podman exec --user 70 mail-postgres \
  pgbackrest --stanza=stalwart --repo=2 info
```

Create an additional reviewed backup without changing the schedule:

```bash
sudo systemctl start mail-pgbackrest-backup@full.service
sudo systemctl start mail-backup-logical-run.service
```

`expire-auto=n` keeps retention changes operator-controlled. The Hetzner host
credential can modify or delete that dedicated hot bucket, while the generated
B2 runtime keys cannot delete objects. Versioning can preserve older hot
versions, but a compromised writer can still disrupt direct PITR. Treat both
hot repositories as availability copies, not immutable history; the signed
logical archives in Scaleway Compliance storage are the ransomware-resistant
recovery boundary. Perform reviewed pgBackRest expiry at least monthly using
the Hetzner credential and a temporary delete-capable B2 credential, confirm a
recent full backup remains in each repository, then revoke the temporary B2
authority.

The declarative Stalwart configuration is in Git and its authoritative config,
blob, lookup, and data store is PostgreSQL. The `mail-stalwart-data` volume is
therefore not a separate backup source. Treat a future storage-backend change
as a backup-boundary change and expand coverage before deploying it.

Run quarterly restore drills into an isolated PostgreSQL instance. For each hot
repository, restore to a fresh data directory with the matching pgBackRest
cipher passphrase and versions selected from before the drill's compromise
cutoff, replay to a recorded timestamp, start PostgreSQL without
Stalwart network exposure, and verify account, mailbox, blob, and configuration
counts. For any signed logical copy, download the ciphertext plus
`.manifest.json` and `.manifest.sig`, verify the Ed25519 signature and manifest
SHA-256/size with `Scripts/verify-logical-backup.sh` before decrypting, then stream it through `age --decrypt`, inspect
it with `pg_restore --list`, and restore into an empty database. Request Glacier
restoration first for Scaleway. Ignore any archive without a valid signature
commit marker. Never test a restore over the production volume.

The age recovery identity and both pgBackRest passphrases must have tested
offline copies. Losing a passphrase makes that repository unrecoverable. Also
verify recovery of `Ansible/inventory/known_hosts` after a host rebuild.

## Rebuilds

Rebuild the server when Butane, Ignition, kernel arguments, SSH policy, or the
gVisor pin changes. A rebuild changes the SSH host key and may replace public
addresses depending on the OpenTofu operation.

Before rebuilding:

1. Verify current application-consistent backups and a restore test.
2. Review DNS TTLs, expected addresses, and mail-delivery impact.
3. Preserve protected OpenTofu state and the age identity.
4. Create and review an OpenTofu plan rather than making console-only changes.
5. Apply the replacement, then run `make install`; the new server starts
   with a `pending` marker and is installed directly through Rescue.
6. Re-establish SSH host-key trust through an independent channel.

Delete protection and rebuild protection are enabled by default. Do not disable
them casually or bypass the reviewed infrastructure lifecycle.

`FCOS_REINSTALL=1 make install` deliberately overwrites the existing
server disk even when its marker is `installed`. It is intended only for a
reviewed in-place reprovision after backups and should not replace the normal
OpenTofu replacement workflow.
