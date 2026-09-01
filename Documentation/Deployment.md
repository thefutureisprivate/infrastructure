# Deployment

## Prerequisites

The operator workstation needs:

- GNU Make and Bash;
- OpenTofu matching `.opentofu-version`;
- SOPS and an age identity matching `SOPS/config.yaml`;
- Ansible Core 2.21;
- `jq`, `curl`, OpenSSL, GNU coreutils, and OpenSSH;
- Podman or Docker for the exact tag-and-digest-pinned Butane,
  coreos-installer, and Stalwart CLI images.

The deployment also needs:

- a Hetzner Cloud project and a read/write API token;
- an existing deSEC zone and a bootstrap token allowed to read it, manage its
  records, and manage child tokens;
- Hetzner Object Storage, Backblaze B2, and Scaleway accounts when mail backups
  are enabled;
- a dedicated Scaleway project for encrypted OpenTofu state and a separate
  dedicated project for the cold mail archive;
- control of the domain's registrar so the existing deSEC nameserver and
  DNSSEC DS records can be verified;
- an SSH public key for the FCOS operator account.

The direct installer currently targets an x86_64 Hetzner CX23. ARM server
families are rejected until the installer transport, Butane policy, and gVisor
pin have an explicit ARM implementation.

When running the operator tooling inside a rootless Distrobox, use the host's
Podman engine rather than starting a second Podman engine against the shared
host storage. Install Distrobox's host-command shim once inside the tools box:

```bash
sudo ln -sfn /usr/bin/distrobox-host-exec /usr/local/bin/podman
hash -r
podman info
```

The repository scripts also detect Distrobox through `CONTAINER_ID` and invoke
`distrobox-host-exec podman` directly, so they remain safe if the command shim
is missing. Place transient bind-mounted files under the shared repository
rather than the container-private `/tmp`:

```bash
mkdir -p build
TMPDIR="$PWD/build" make install
```

Running local rootless Podman directly inside Distrobox is unsupported for
this workflow because its PID namespace cannot safely reuse the host engine's
pause-process metadata. The direct installer uses Podman's `keep-id` user
namespace while extracting the pinned CoreOS Installer and its exact runtime
libraries into an operator-owned temporary bind mount.

## Prepare SOPS and age

The committed encrypted files are already bound to the public recipients in
`SOPS/config.yaml`. Place a matching private age identity at SOPS's standard
path:

```text
~/.config/sops/age/keys.txt
```

Set `SOPS_AGE_KEY_FILE` if the identity is restored elsewhere. Never place a
private age identity in this repository.

For a new fork with a new recipient policy, generate an identity and obtain its
public recipient:

```bash
install -d -m 0700 "$HOME/.config/sops/age"
age-keygen -o "$HOME/.config/sops/age/keys.txt"
age-keygen -y "$HOME/.config/sops/age/keys.txt"
```

Copy `SOPS/config.example.yaml` to `SOPS/config.yaml`, replace its placeholder
with the public recipient, and initialize new encrypted files only when the
active files do not already exist:

```bash
make sops-infrastructure-init
make sops-mail-init
```

The initialization targets refuse to overwrite existing encrypted files.

## Configure Credentials

Edit the provider scope:

```bash
make sops-infrastructure-edit
```

Set:

- `HCLOUD_TOKEN` to the Hetzner project token;
- `DESEC_API_TOKEN` to the deSEC bootstrap token with zone read/write and
  token-management authority;
- `SCW_ACCESS_KEY` and `SCW_SECRET_KEY` to the operator-side Scaleway identity
  that owns the state and backup projects;
- `TOFU_STATE_PASSPHRASE` to at least 32 random characters, with an offline
  recovery copy;
- `MINIO_USER` and `MINIO_PASSWORD` to the S3 key for a dedicated Hetzner
  project containing only the mail-backup bucket; this single pair manages the
  bucket and is synchronized to the mail host for both backup paths;
- `B2_APPLICATION_KEY_ID` and `B2_APPLICATION_KEY` to an operator-side B2 key
  allowed to manage the dedicated hot bucket and create its runtime key.

The Hetzner, B2, and Scaleway provider values are needed only when the
three-provider backup boundary is enabled. The B2 and Scaleway provider values
remain operator-side. The Hetzner pair is intentionally shared with the mail
host, so keep its project dedicated to this one mutable hot-backup bucket.

Edit the application scope:

```bash
make sops-mail-edit
```

Set distinct random values of at least 32 characters for
`MAIL_POSTGRES_ADMIN_PASSWORD`, `MAIL_POSTGRES_PASSWORD` (the non-superuser
Stalwart login), and `MAIL_POSTGRES_DUMP_PASSWORD` (the read-only logical dump
login). For backups, generate independent random values of at least 32
characters for `PGBACKREST_REPO1_CIPHER_PASS` and
`PGBACKREST_REPO2_CIPHER_PASS`, and retain tested offline copies. Run
`make sops-mail-generate-backup-signing-key` to create the initial separate
Ed25519 signing pair directly inside SOPS or idempotently register its public
key in `SOPS/backup-signing-public-keys/`. Commit that non-secret public key.
Use only `make sops-mail-rotate-backup-signing-key` for an intentional rotation;
it retains the previous public key so older archives remain verifiable. Do not
manually invent `STALWART_DESEC_API_TOKEN`, the Hetzner runtime values, either
B2 runtime key, or the Scaleway cold-write key; the apply workflow synchronizes
those values into mail SOPS.

SOPS decrypts each scope only into the child process selected by the Make
target. Plaintext secret files and shell exports are not part of the workflow.

## Configure Infrastructure

Create the ignored deployment variables file:

```bash
cp OpenTofu/terraform.tfvars.example OpenTofu/terraform.tfvars
```

Review the fixed `thefutureisprivate.dev` deSEC zone and:

- Hetzner location and CX23 server type;
- the fleet-wide `nodes` map and `mail_server_node_key` role assignment;
- the mail subname used for forward and reverse DNS;
- `OpenTofu/stalwart-authority.tfvars.json`, whose reviewed DKIM selectors and
  ACME account are authorization inputs rather than workload discovery;
- `mail_ingress_rules`, which are attached only to the selected mail node;
- `primary_ip_import_ids`, which adopts an existing deployment's IPv4 and IPv6
  resource IDs without changing their addresses (leave empty for new nodes);
- the three distinct mail-backup bucket names, the Paris Scaleway region,
  dedicated Scaleway cold-project ID, and public backup age recipient;
- billable backups and delete protection.

Generate the backup age identity on an offline recovery medium and place only
its public `age1...` recipient in `mail_backup_age_recipient`. Keep it distinct
from the workstation SOPS identity so compromise of routine deployment access
does not also reveal cold backup plaintext.

SSH and ICMP rules are built into the base firewall shared by every node. SSH
accepts connections from all IPv4 and IPv6 sources by design, while
authentication remains public-key only. The separate mail firewall is attached
only to `mail_server_node_key`, so adding another VPS does not expose mail
ports or enroll it in the mail Ansible group.

Do not remove an existing node from `primary_ip_import_ids` as a routine
change. The provider cannot safely convert its legacy automatic attachment to
an explicit ID in place. Imported addresses are already protected independently;
new nodes use explicit protected Primary IPs from their first creation.

## Plan and Apply

Bootstrap the versioned remote-state bucket before the main root. Copy and edit
the ignored bootstrap variables, then apply with encrypted local bootstrap
state:

```bash
cp OpenTofu/bootstrap/terraform.tfvars.example OpenTofu/bootstrap/terraform.tfvars
make tofu-backend-bootstrap
cp OpenTofu/backend.hcl.example OpenTofu/backend.hcl
```

Copy the non-secret bucket, endpoint, and region from the bootstrap output into
`backend.hcl`. Credentials remain in SOPS and are not written to that file. For
a new root, initialize the provider lock and remote backend:

```bash
make tofu-init
```

The wrapper has no plaintext compatibility mode: state and saved plans must use
PBKDF2-derived AES-GCM encryption from their creation. It fails closed if a
plaintext `terraform.tfstate*` or plan artifact appears in either root.

The S3 backend is authoritative: OpenTofu does not maintain a synchronized
local state file when a remote backend is active. Successful `make apply`
creates an additional timestamped recovery
snapshot under the git-ignored `OpenTofu/state-snapshots/` directory. The
snapshot command streams the decrypted backend state directly into SOPS,
encrypts it to the repository's age recipient, and never persists plaintext.
Create another snapshot after a manual import or other direct state mutation:

```bash
make tofu-state-snapshot
```

These files are recovery copies, not writable state backends. They protect
against accidental deletion of the remote bucket, but they are not a separate
failure domain if the workstation is lost. Preserve the SOPS age identity in
tested offline custody. After confirmed loss of the remote state, recreate and
initialize the empty backend, review the selected snapshot, and restore it
without writing decrypted JSON to disk:

```bash
make tofu-state-restore \
  TOFU_STATE_SNAPSHOT=OpenTofu/state-snapshots/infrastructure-<timestamp>.sops.json
```

Create a saved plan:

```bash
make plan
```

Review the plan before applying it. In particular, confirm the final server's
`nbg1` location, transient native bootstrap image, firewall ports, server
addresses, DNS zone, controller-owned static RRsets, and every exact Stalwart
token policy. OpenTofu does not manage any Stalwart-owned mail records.

Apply the saved plan:

```bash
make apply
```

After OpenTofu finishes, the Make target reads the sensitive Stalwart child
token plus generated B2 pgBackRest, B2 signed-archive, and Scaleway runtime
backup keys from encrypted state. It also copies the dedicated Hetzner backup
pair from infrastructure SOPS. All runtime values are written directly into
`SOPS/mail.sops.yaml` through `sops set --value-stdin`; no plaintext credential
file is retained. The synchronizer also removes the retired separate Hetzner
pgBackRest fields from mail SOPS.

Inspect the non-secret outputs:

```bash
make tofu-output
```

Sensitive values remain redacted by the human-readable output command.

Compare the deSEC delegation and DS records with the registrar. DNSSEC is not
complete unless the registrar publishes the expected DS records.

For the initial backup rollout, keep both backup flags false until the
encrypted remote backend is operational. Create one S3 credential pair in a
dedicated Hetzner project, store it as `MINIO_USER` and `MINIO_PASSWORD`, set all
backup variables, set `mail_backup_storage_enabled = true`, and apply the
reviewed plan that creates the protected buckets. Keep that storage flag true, set
`mail_backup_enabled = true`, and apply a second reviewed plan to create fresh
runtime identities and publish the host schedules. Then run:

```bash
make inventory
make deploy
```

If an earlier deployment stored pgBackRest data directly under `stalwart/`,
copy both repositories into `stalwart/pgbackrest/` with trusted maintenance
credentials before deploying this prefix split. Verify both copies before
revoking the old grants.

Deployment first reconciles the administrator, non-superuser Stalwart, and
read-only dump roles before PostgreSQL is considered started. The controller
builds the pinned PostgreSQL-derived backup image, transfers a checksum-verified
OCI archive over the pinned SSH channel, and the VPS only loads that reviewed
artifact; no image build runs on the server. Deployment then initializes both encrypted
pgBackRest stanzas, and starts the full, differential, logical, and
repository-check timers. Treat successful `mail-pgbackrest-init.service` and a
manual full backup as rollout gates.

## Install Fedora CoreOS Directly

OpenTofu creates the final server with the operator public key and a
`fcos-installation=pending` marker. Compile Ignition, boot each pending server
into Hetzner Rescue, overwrite its unmounted disk with signature-verified FCOS,
and reboot it into the installed system:

```bash
make install
```

The command creates no temporary VPS and no snapshot. It extracts
`coreos-installer` and its runtime libraries from the immutable image in
`Tools/compose.yaml`, hashes the transferred bundle and Ignition document,
activates Rescue through the Hetzner API, verifies that the target disk is a
supported unmounted block device, and lets CoreOS Installer verify Fedora's OS
image signature. The installed kernel arguments enable DHCP in the initramfs so
Afterburn can reach Hetzner's link-local metadata service before Ignition
completes. After SSH confirms an FCOS ostree boot, the marker changes to
`awaiting-verification`. Add the independently verified permanent host key to
`Ansible/inventory/known_hosts` and rerun `make install`; only a strict pinned
SSH check with non-interactive operator sudo and working gVisor changes it to
`installed`. A
normal second run skips that node.

Optional environment variables are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `FCOS_STREAM` | `stable` | Fedora CoreOS stream installed by coreos-installer |
| `FCOS_NODE_KEY` | all declared nodes | Install one key from the OpenTofu `nodes` map |
| `FCOS_INSTALL_DEVICE` | `/dev/sda` | Exact Rescue-visible disk to overwrite |
| `SSH_PRIVATE_KEY_FILE` | SSH agent/default key | Explicit private key matching `Butane/files/operator.pub` |
| `CONTAINER_RUNTIME` | `auto` | `auto`, `podman`, or `docker` |
| `FCOS_REINSTALL` | `0` | Set to `1` only for an intentional destructive reinstall |

`FCOS_ARCHITECTURE` is fixed to `x86_64`; other values fail before Rescue is
activated. An interrupted installation leaves the marker at `installing`, so
the same command can retry it. Once it reaches `installed`, only the explicit
`FCOS_REINSTALL=1` override permits another disk overwrite.

Ignition grants the key-only `thefutureisprivate` operator account a
user-specific passwordless sudo rule. Ansible needs that privilege to
reconcile root-owned Podman secrets, support files, and Quadlets. Treat the
matching SSH private key as a root credential; no global `wheel` sudo policy is
changed.

The temporary Rescue SSH host key is accepted into an isolated temporary
known-hosts file because Hetzner generates it on every Rescue boot. No secret
application credentials are sent to Rescue. This does not establish trust in
the permanent FCOS host key; verify that key independently in the next step.

## Establish SSH Trust

Render the generated inventory:

```bash
make inventory
```

The generated inventory includes every VPS in `fcos` and only the selected mail
node in `mail`. Its `ansible_host` values are the deSEC-managed node FQDNs, so
OpenSSH can connect through either the published A or AAAA address and retry the
other family if necessary. Ansible enforces host-key checking and uses only
`Ansible/inventory/known_hosts`. Obtain the new server's host-key fingerprint
through an independent trusted channel, such as the Hetzner console, and
compare it before adding the key.

After verification, write the accepted public host key to:

```text
Ansible/inventory/known_hosts
```

Pin the FQDN rather than only one address so the same verified key covers both
address families, for example:

```text
mail.thefutureisprivate.dev ssh-ed25519 <VERIFIED_PUBLIC_HOST_KEY>
```

Do not treat an unauthenticated `ssh-keyscan` result as verification. Both the
generated inventory and known-hosts file are ignored by Git.

## Deploy and Bootstrap Stalwart

Run the complete bootstrap workflow from an interactive terminal:

```bash
make stalwart-bootstrap
```

The target generates a fresh 256-bit recovery password and then automatically:

1. creates a randomly named rootful Podman secret on the server and reconciles
   the mail stack with that recovery administrator plus a temporary
   loopback-only HTTP listener;
2. opens the permitted local SSH forward and uses the pinned Stalwart CLI;
3. installs the checksum-verified local Web UI Application;
4. configures the deSEC provider, server identity, services, Domain, automatic
   DKIM, and both Let's Encrypt ACME providers;
5. verifies the exact generated DKIM selectors and active ACME account URI
   against `OpenTofu/stalwart-authority.tfvars.json`, applies only those
   reviewed deSEC token policies, publishes the OpenTofu-owned CAA RRsets, and
   transfers MX, SPF, SRV, Microsoft Autodiscover, DMARC, and TLS-RPT
   publication to Stalwart;
6. on the first rollout only, proves DNS-01 issuance with Let's Encrypt
   staging, switches to production, retires only that verified staging
   certificate while certificate management is temporarily Manual, and
   verifies the automatically issued,
   hostname-valid production certificate and account/method-bound `mail` CAA
   policy while the apex critically denies TLS, wildcard, S/MIME, and BIMI
   mark-certificate issuance; reruns keep production certificate management
   selected, including while managed DNS is refreshed;
7. displays the one-run recovery credential so a regular administrator can be
   created or repaired and tested at the trusted public Web UI;
8. removes the SSH tunnel, reconciles the normal production Quadlet, and then
   deletes the server-side recovery secret on every exit, including failure.
   If the production reconciliation itself fails, the target deliberately
   preserves the named secret and reports it so the still-running recovery
   deployment remains repairable; run `make deploy`, then remove that exact
   Podman secret as instructed.

On a genuinely fresh Stalwart data volume, the first invocation may stop after
creating the ACME accounts because their server-issued account URIs cannot be
reviewed in advance. Inspect those public identities, update and commit
`OpenTofu/stalwart-authority.tfvars.json`, then rerun the same target. The
Domain retains the `staged enrollment pending` marker across retries and
interruptions, so the rerun still performs staging before production. The
production plan clears that marker only after the reviewed transition begins.

The recovery password exists only in bootstrap process memory and transient
Podman secrets on the controller and server. It is not written to SOPS,
OpenTofu variables, a command line, or a regular file. The mail playbook
validates controller-side inputs, downloads Web UI v1.0.8 and
verifies its committed SHA-256 before an atomic root-owned install, creates
rootful Podman secrets over SSH standard input, installs the public-service and
internal database networks and named volumes, writes support files and Quadlets
atomically, reloads systemd, and starts or restarts only changed services.

Verify the result:

```bash
ssh thefutureisprivate@SERVER_ADDRESS
sudo systemctl status gvisor-install.service mail-postgres.service mail-stalwart.service
sudo podman ps
sudo podman inspect --format '{{.OCIRuntime}}' mail-postgres mail-stalwart
```

Both inspect results should identify `runsc`. Confirm that
`https://mail.thefutureisprivate.dev` now presents the trusted production
certificate. Sign in to the verified Web UI with the regular administrator,
create the narrowly scoped hardening API key
documented in [Stalwart Production Setup](Stalwart.md), and store its one-time
secret as `STALWART_CONFIG_API_TOKEN`:

```bash
make sops-mail-edit
make stalwart-harden
make deploy
make stalwart-audit
```

The automated bootstrap has already removed the host-loopback port 8080
publication. The hardening plan preserves the verified local Application and
removes Stalwart's cleartext bootstrap listener and all undeclared protocol
listeners. Its final audit verifies the exact live Stalwart configuration,
HTTPS response headers including CSP and HSTS, and hostname-valid implicit TLS
on submission and IMAPS.

Application bootstrap and mail policy remain intentionally separate from the
base infrastructure lifecycle. A server is not production-ready merely
because the two containers are running.
