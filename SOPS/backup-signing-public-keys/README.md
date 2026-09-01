# Backup signing public keys

This keyring contains non-secret Ed25519 public keys named by the SHA-256 of
their DER-encoded SubjectPublicKeyInfo. `make sops-mail-generate-backup-signing-key`
registers the current key without replacing it; the explicit rotation target
retains the old public key before installing a new active pair in SOPS.

Commit every generated `.pem` file. Offline restore verification depends on
retaining the public key referenced by each version-2 manifest; the verifier
also tries every retained key for legacy version-1 manifests.
