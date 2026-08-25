# SOPS secrets

All secret-management configuration, encrypted files, safe examples, and
helper scripts live in this directory. The two secret scopes are deliberately
separate:

- `infrastructure.sops.yaml` supplies `HCLOUD_TOKEN` and a deSEC bootstrap
  `DESEC_API_TOKEN` only to OpenTofu and the direct FCOS Rescue installer. The
  deSEC token reads the existing zone, manages the mail host records, and
  needs token-management permission so OpenTofu can mint the restricted
  Stalwart child token.
- `mail.sops.yaml` starts with `MAIL_POSTGRES_PASSWORD`. After `make apply`, it
  also contains the generated `STALWART_DESEC_API_TOKEN`. Ansible converts
  those two values into rootful Podman secrets on the FCOS host; neither is
  rendered into a Quadlet or Stalwart's configuration file. The same encrypted
  scope later holds `STALWART_CONFIG_API_TOKEN`, which is passed only to the
  local declarative hardening client and is never deployed to the server as a
  Podman secret.

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

`make apply` creates the Stalwart token and immediately writes it to
`mail.sops.yaml` through `sops set --value-stdin`. The token is never placed in
a command-line argument or plaintext temporary file. Run
`make sops-mail-sync-desec` to retry this synchronization without reapplying
infrastructure.

After the permanent Stalwart HTTPS listener works, create the API key described
in `Documentation/Stalwart.md` and store its one-time secret with
`make sops-mail-edit` under `STALWART_CONFIG_API_TOKEN`.
`make stalwart-harden` and `make stalwart-audit` decrypt it directly into the
pinned, read-only Stalwart CLI container. The key uses `Replace` permission
mode with only the baseline `authenticate` permission and the listener, HTTP,
and SMTP-auth read/write permissions required by the committed plan.

The generated token is retained in OpenTofu state so it can be synchronized
again. Use an encrypted remote backend with tightly restricted access before
sharing or automating this stack; marking an output sensitive only suppresses
normal CLI display and does not encrypt state.

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
