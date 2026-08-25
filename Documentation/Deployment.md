# Deployment

## Prerequisites

The operator workstation needs:

- GNU Make and Bash;
- OpenTofu matching `.opentofu-version`;
- SOPS and an age identity matching `SOPS/config.yaml`;
- Ansible Core 2.20;
- `jq`, `curl`, OpenSSL, GNU coreutils, and OpenSSH;
- Podman or Docker for the exact tag-and-digest-pinned Butane,
  coreos-installer, hcloud-upload-image, and Stalwart CLI images.

The deployment also needs:

- a Hetzner Cloud project and a read/write API token;
- an existing deSEC zone and a bootstrap token allowed to read it, manage its
  records, and manage child tokens;
- control of the domain's registrar so the existing deSEC nameserver and
  DNSSEC DS records can be verified;
- an SSH public key for the FCOS operator account.

The current host profile targets an x86_64 Hetzner CX23. Review the architecture
constraints before selecting ARM or another server family.

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
- `stalwart_acme_account_id`, copied from the numeric suffix of Stalwart's
  production Let's Encrypt `accountUri`;
- `stalwart_dkim_selectors`, copied exactly from Stalwart's reviewed generated
  zone before automatic DNS publication is enabled;
- `mail_ingress_rules`, which are attached only to the selected mail node;
- billable backups and delete protection.

SSH and ICMP rules are built into the base firewall shared by every node. SSH
accepts connections from all IPv4 and IPv6 sources by design, while
authentication remains public-key only. The separate mail firewall is attached
only to `mail_server_node_key`, so adding another VPS does not expose mail
ports or enroll it in the mail Ansible group.

## Upload Fedora CoreOS

Import the current stable FCOS Hetzner image:

```bash
make image
```

Optional environment variables are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `FCOS_STREAM` | `stable` | Fedora CoreOS stream |
| `FCOS_ARCHITECTURE` | `x86_64` | Download architecture |
| `FCOS_LOCATION` | `fsn1` | Location used by the temporary upload server |
| `CONTAINER_RUNTIME` | `auto` | `auto`, `podman`, or `docker` |

The uploader creates a temporary billable server and a persistent snapshot.
It labels the snapshot so OpenTofu can select the newest matching image.

## Plan and Apply

Initialize the provider lock and modules:

```bash
make tofu-init
```

Compile Ignition with the committed operator key and create a saved plan:

```bash
make plan
```

Review the plan before applying it. In particular, confirm the selected FCOS
snapshot, firewall ports, server addresses, DNS zone, declarative RRset
imports, apex-deny and mail-specific CAA policy, and every exact token policy.
The first apply
adopts only the RRsets listed in `OpenTofu/zone.tf`; it does not manage any
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

## Establish SSH Trust

Render the generated inventory:

```bash
make inventory
```

The generated inventory includes every VPS in `fcos` and only the selected mail
node in `mail`. Ansible enforces host-key checking and uses only
`Ansible/inventory/known_hosts`. Obtain the new server's host-key fingerprint
through an independent trusted channel, such as the Hetzner console, and
compare it before adding the key.

After verification, write the accepted public host key to:

```text
Ansible/inventory/known_hosts
```

Do not treat an unauthenticated `ssh-keyscan` result as verification. Both the
generated inventory and known-hosts file are ignored by Git.

## Deploy Bootstrap Quadlets

Reconcile the mail stack with the temporary loopback-only bootstrap
publication:

```bash
make deploy-bootstrap
```

The mail playbook targets only the `mail` inventory group. It validates all
controller-side inputs, downloads Web UI v1.0.8 and verifies its committed
SHA-256 before an atomic root-owned install, creates rootful Podman secrets
over SSH standard input, installs the private network and named volumes,
writes support files and Quadlets atomically, reloads systemd, and starts or
restarts changed services.

Verify the result:

```bash
ssh thefutureisprivate@SERVER_ADDRESS
sudo systemctl status gvisor-install.service mail-postgres.service mail-stalwart.service
sudo podman ps
sudo podman inspect --format '{{.OCIRuntime}}' mail-postgres mail-stalwart
```

Both inspect results should identify `runsc`.

## Complete Stalwart Setup

Stalwart's HTTP bootstrap listener is bound to host loopback on port 8080. The
Hetzner firewall does not expose it. The SSH drop-in permits only a local
forward to that exact loopback destination. Start the authenticated tunnel:

```bash
ssh -N -L 127.0.0.1:8080:127.0.0.1:8080 \
  thefutureisprivate@mail.thefutureisprivate.dev
```

Retrieve the one-time bootstrap credentials from the service log when needed:

```bash
sudo journalctl -u mail-stalwart.service
```

Before opening any Stalwart page, replace the server's default network-fetched
Application with the checksum-verified read-only bundle already mounted by
Ansible:

```bash
make stalwart-webui-bootstrap
```

The pinned CLI prompts for the temporary bootstrap password, connects only to
`127.0.0.1:8080` through the tunnel, reconciles the Application to
`file:///opt/stalwart-webui/webui.zip`, and reads it back. Only after that
command succeeds should you open `http://127.0.0.1:8080/admin`. Do not expose
port 8080 publicly.

Follow [Stalwart Production Setup](Stalwart.md) for the exact identity,
listeners, ACME, deSEC, account, DNS, and CAA settings. Confirm that
`https://mail.thefutureisprivate.dev` works, create the narrowly scoped
hardening API key documented there, and store its one-time secret as
`STALWART_CONFIG_API_TOKEN`:

```bash
make sops-mail-edit
make stalwart-harden
make deploy
make stalwart-audit
```

The hardening plan preserves the verified local Application, removes the
cleartext bootstrap listener and all undeclared protocol listeners. The normal
deployment removes the host-loopback port 8080 publication. Its final audit
verifies the exact live Stalwart configuration, HTTPS response headers
including CSP and HSTS, and hostname-valid implicit TLS on submission and
IMAPS.

Application bootstrap and mail policy are intentionally separate from the
infrastructure lifecycle. A server is not production-ready merely because the
two containers are running.
