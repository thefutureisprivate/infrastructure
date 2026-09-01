# SOPS secrets

All secret-management configuration, encrypted files, safe examples, and
helper scripts live in this directory. The two secret scopes are deliberately
separate:

- `infrastructure.sops.yaml` supplies `HCLOUD_TOKEN`, the deSEC bootstrap
  `DESEC_API_TOKEN`, operator-side Hetzner/B2/Scaleway object-storage
  credentials, and `TOFU_STATE_PASSPHRASE` to scoped children. The B2 and
  Scaleway provider credentials remain operator-side and mint restricted
  runtime identities. The Hetzner pair is also synchronized to the mail scope
  for its dedicated mutable backup bucket.
- `mail.sops.yaml` starts with independent PostgreSQL administrator,
  application, and read-only dump passwords. After `make apply`, it also
  contains the generated `STALWART_DESEC_API_TOKEN`, bucket-scoped B2 keys,
  write-only Scaleway cold-archive key, synchronized Hetzner pair, and two
  independent pgBackRest cipher passphrases.
  Ansible converts deployed values into rootful Podman secrets; none is
  rendered into a Quadlet or Stalwart configuration file. The same encrypted
  scope holds `STALWART_CONFIG_API_TOKEN`, which is passed only to the local
  declarative hardening client and is never deployed as a Podman secret.

OpenTofu creates Stalwart's deSEC token with a default-deny policy. Its writes
are limited to exact reviewed mail owner-name/type pairs and declared DKIM
selectors, and authentication is limited to the mail server's public
addresses. Its sole CAA grant is the mail-domain apex so Stalwart can publish
the policy bound to its registered ACME account; it cannot write unrelated
names or TLSA/A/AAAA records, create or delete domains, or manage tokens. The
deSEC account retains zone lifecycle authority; OpenTofu owns the declared
host A/AAAA records, while Stalwart owns the mail-domain records selected in
its automatic DNS-management configuration.

Edit the encrypted secret scopes directly:

```bash
make sops-infrastructure-edit
make sops-mail-edit
```

The `*.example.yaml` files remain as non-secret references and for bootstrapping
a fresh environment. The current secret scopes are already initialized; the
`sops-*-init` Make targets refuse to overwrite them.

`make apply` creates the Stalwart token and generated runtime backup identities,
then synchronizes them together with the Hetzner pair into `mail.sops.yaml`.
Secrets are never placed in command-line arguments or plaintext files; the
backup synchronizer retains its sensitive JSON only in shell memory. Run
`make sops-mail-sync-desec` or `make sops-mail-sync-backup` to retry one
synchronization without reapplying infrastructure.

After the permanent Stalwart HTTPS listener works, create the API key described
in `Documentation/Stalwart.md` and store its one-time secret with
`make sops-mail-edit` under `STALWART_CONFIG_API_TOKEN`.
`make stalwart-harden` and `make stalwart-audit` decrypt it directly into the
pinned, read-only Stalwart CLI container. The key uses `Replace` permission
mode with only the baseline `authenticate` permission and the listener, HTTP,
inbound SMTP throttle, SMTP-auth, MTA-STS, DNS-resolver, and settings-reload
permissions required by the committed plan.

`make stalwart-bootstrap` separately generates a fresh 256-bit recovery
password. A direct CLI runtime receives it only in the scoped child environment;
Distrobox uses a transient host-Podman secret, while the temporary server
Quadlet reads `admin:<password>` from a separate rootful Podman secret. The exit
trap restarts the production Quadlet without the recovery environment before
removing both secrets. If that restart fails, it preserves and reports the
server secret until `make deploy` succeeds rather than falsely treating the
still-active recovery credential as revoked. The workflow decrypts the infrastructure scope solely
for a targeted update of the exact reviewed DKIM token policies; the recovery
password is never added to either SOPS file, a command argument, or a regular
file. DKIM selectors and ACME account URIs are non-secret authorization inputs
committed in `OpenTofu/stalwart-authority.tfvars.json` for review.

Generated credentials are retained in OpenTofu state so they can be synchronized
again. `Scripts/tofu.sh` derives an AES-GCM key from
`TOFU_STATE_PASSPHRASE`; normal wrapper mode enforces encrypted state and
plans for both roots. The remote Scaleway bucket is versioned, while its backend
credentials remain environment-only. There is no plaintext state compatibility
path. Preserve the state passphrase offline: the remote objects are
unrecoverable without it. Timestamped local state recovery copies are wrapped
independently with SOPS/age and can be restored through `make
tofu-state-restore` after recreating the empty backend.

The cold-backup age identity is a separate recovery authority. The mail host
receives only its public recipient. Keep the private identity offline and test
it quarterly together with both independent pgBackRest cipher passphrases.

The public recipient policy is committed in `SOPS/config.yaml`. Its private age
identity is stored at `~/.config/sops/age/keys.txt`, SOPS's standard user path.
Back this identity up securely outside the repository; losing every matching
private identity makes the encrypted files unrecoverable. Set
`SOPS_AGE_KEY_FILE` when using a restored identity stored elsewhere. Private
age identities must never enter this repository.

The encrypted `*.sops.yaml` files contain a top-level `sops` metadata block and
are safe to commit. Plain `SOPS/infrastructure.yaml` and `SOPS/mail.yaml` files
remain ignored as a guard against accidental migrations, but the deployment
reads only the encrypted files. Every `SOPS/exec-env.sh` call names an explicit
allowlist. The wrapper removes inherited known-secret variables, decrypts the
flat map through a pipe, exports only requested values, and fails if one is
missing or non-scalar. Plaintext secrets are not written to a temporary file or
passed as command-line arguments.
