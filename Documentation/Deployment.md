# Deployment

## Prerequisites

The operator workstation needs:

- GNU Make and Bash;
- OpenTofu matching `.opentofu-version`;
- SOPS and an age identity matching `SOPS/config.yaml`;
- Ansible Core 2.20;
- `jq`, `curl`, OpenSSL, GNU coreutils, and OpenSSH;
- Podman or Docker for the exact tag-and-digest-pinned Butane,
  coreos-installer, and Stalwart CLI images.

The deployment also needs:

- a Hetzner Cloud project and a read/write API token;
- an existing deSEC zone and a bootstrap token allowed to read it, manage its
  records, and manage child tokens;
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
  token-management authority.

Edit the application scope:

```bash
make sops-mail-edit
```

Set `MAIL_POSTGRES_PASSWORD` to a unique random value of at least 32 characters.
Do not manually invent `STALWART_DESEC_API_TOKEN`; OpenTofu creates and
synchronizes it after apply.

SOPS decrypts each scope only into the child process selected by the Make
target. Plaintext secret files and shell exports are not part of the workflow.

## Configure Infrastructure

Create the ignored deployment variables file:

```bash
cp OpenTofu/terraform.tfvars.example OpenTofu/terraform.tfvars
```

At minimum, replace `example.com` with the deSEC zone and review:

- Hetzner location and CX23 server type;
- the fleet-wide `nodes` map and `mail_server_node_key` role assignment;
- the mail subname used for forward and reverse DNS;
- `stalwart_dkim_selectors`; leave this bootstrap input empty because
  `make stalwart-bootstrap` discovers the exact live selectors and writes the
  ignored generated override before automatic DNS publication is enabled;
- `mail_ingress_rules`, which are attached only to the selected mail node;
- `primary_ip_import_ids`, which adopts an existing deployment's IPv4 and IPv6
  resource IDs without changing their addresses (leave empty for new nodes);
- billable backups and delete protection.

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

Initialize the provider lock and modules:

```bash
make tofu-init
```

Create a saved plan:

```bash
make plan
```

Review the plan before applying it. In particular, confirm the final server's
`nbg1` location, transient native bootstrap image, firewall ports, server
addresses, DNS zone, declarative RRset imports, and every exact Stalwart token
policy. The first apply adopts only the RRsets
listed in `OpenTofu/zone.tf`; it does not manage any
Stalwart-owned mail records.

Apply the saved plan:

```bash
make apply
```

After OpenTofu finishes, the Make target reads the sensitive Stalwart child
token from state and writes it directly into `SOPS/mail.sops.yaml` through
`sops set --value-stdin`.

Inspect the non-secret outputs:

```bash
tofu -chdir=OpenTofu output servers
tofu -chdir=OpenTofu output dns_records
tofu -chdir=OpenTofu output stalwart_desec_token_scope
tofu -chdir=OpenTofu output desec_dnssec_ds_records
```

Compare the deSEC delegation and DS records with the registrar. DNSSEC is not
complete unless the registrar publishes the expected DS records.

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
`installed`; that final check also requires non-interactive operator sudo. A
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
5. records the exact generated DKIM selectors and active ACME account URI in
   the ignored `OpenTofu/stalwart-dkim.generated.tfvars.json` file, applies the
   matching deSEC token policies, and publishes the OpenTofu-owned CAA, DMARC,
   and TLS-RPT RRsets;
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

The recovery password exists only in bootstrap process memory and transient
Podman secrets on the controller and server. It is not written to SOPS,
OpenTofu variables, a command line, or a regular file. The mail playbook
validates controller-side inputs, downloads Web UI v1.0.8 and
verifies its committed SHA-256 before an atomic root-owned install, creates
rootful Podman secrets over SSH standard input, installs the private network
and named volumes, writes support files and Quadlets atomically, reloads
systemd, and starts or restarts only changed services.

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
