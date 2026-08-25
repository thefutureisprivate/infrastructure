# Security Finding Closure

The Codex Security scan completed on 24 August 2026 reported seven findings.
All seven repository-level attack paths were remediated and independently
reviewed on 25 August 2026. The identifiers below are the immutable occurrence
IDs from scan `14312600-da63-4274-9ff4-fb12906e5115`.

`fixed` means the vulnerable source-to-sink path no longer reproduces in the
repository, the legitimate path passes its focused regression, and the complete
local validation gate passes. It does not mean that production infrastructure
was mutated during verification.

## Closed findings

### `occ_184ed5b57b8eeca80dad3422`: deSEC DNS scope

Status: `fixed`

- The Stalwart child token is default-deny and each allow policy now contains an
  exact domain, owner name, and RR type. DKIM selectors are explicit inputs.
- Apex CAA denies issuance. The mail-host exception authorizes only the pinned
  Let's Encrypt account using DNS-01 and denies wildcard issuance.
- OpenTofu formatting and validation pass. Static review confirms that `www`,
  arbitrary `_acme-challenge` labels, A, AAAA, CAA, and token management are not
  delegated.

### `occ_09ecd2927916b45b4e27a423`: deployment tool identity

Status: `fixed`

- Butane, coreos-installer, and hcloud-upload-image are container-only and locked
  by readable version plus immutable image digest in `Tools/compose.yaml`.
- The resolver rejects missing, duplicate, or non-digest image references. PATH
  executables and mutable `release` fallbacks were removed.
- Offline provenance policy, exact-image help paths, and an actual Butane render
  pass. A real Hetzner image upload was intentionally not run because it creates
  billable infrastructure.

### `occ_751ffd3ffb85224d202db766`: SOPS environment exposure

Status: `fixed`

- Every SOPS command declares an explicit environment allowlist. The wrapper
  removes inherited repository secret names before decrypting and exports only
  requested flat string values.
- The wrapper waits for the complete SOPS/JQ pipeline before exporting or
  executing. A decryptor that emits valid-looking JSON and then fails cannot
  launch the requested command.
- Regression tests cover selection, inherited-value scrubbing, missing keys, and
  late decrypt failure propagation.

### `occ_d3b5cb9e9d55aad3e992bdf5`: Ansible secret transport

Status: `fixed`

- The Quadlet action plugin sends the exact secret bytes through SSH standard
  input. Neither plaintext nor a reversible encoding appears in remote command
  text or task output.
- The remote command contains only validated non-secret parameters and a
  SHA-256 state value. Managed state is root-owned and mode `0600`.
- Tests preserve multiline shell metacharacters byte-for-byte and the second
  Ansible run reports zero changes.

### `occ_9f2baec927d6a554442f839a`: implicit-TLS hostname

Status: `fixed`

- SMTP submission and IMAPS audits now combine SNI, certificate-chain
  verification, and explicit `openssl s_client -verify_hostname` checking.
- Shell syntax and the complete repository gate pass. A live endpoint audit is
  an explicit post-deployment operation.

### `occ_7489bd8b294f21e9ba3dd6f1`: Stalwart Web UI authenticity

Status: `fixed`

- The exact Web UI release is pinned by SHA-256, downloaded over HTTPS-only
  redirects, verified before atomic installation, and mounted read-only.
- Stalwart is reconciled to the verified local `file://` bundle. The loopback-only
  bootstrap applies and reads back that Application before browser use.
- The pinned artifact checksum and ZIP root were verified. Declarative audit and
  CI reject drift from the local resource URL.

### `occ_c48975600b69dff7e908b5c3`: CI Python dependencies

Status: `fixed`

- Every direct and transitive validation dependency is exact-version and
  hash-locked. CI accepts wheels only and requires every hash.
- Installation under the CI Python version and `pip check` pass. Dependabot owns
  lock updates after the repository-wide seven-day cooldown.

## Verification ledger

The ordered verification gates passed:

1. Shell and Python syntax/import checks.
2. SOPS allowlist and late-failure regressions.
3. OpenTofu formatting and validation with OpenTofu 1.12.6.
4. Immutable container-reference policy and Butane Ignition rendering.
5. Stalwart hardening-plan assertions and pinned Web UI checksum inspection.
6. Hash-only, wheel-only Python dependency installation and `pip check`.
7. Ansible syntax, production-profile lint, stdin-only secret test, and two-pass
   idempotence (`changed=0` on the second run).
8. The complete `Scripts/check.sh` repository gate.

An independent bypass-and-regression review found one late SOPS pipeline-status
gap. That gap was fixed, its reproducer was added to the test suite, and the full
gate was rerun successfully. The final independent verdict found no surviving
route through any of the seven reported boundaries.

Live DNS denial probes, live Stalwart endpoint audits, and the billable Hetzner
image-upload path remain deployment checks. They require production credentials
or state changes and were not used as substitutes for repository verification.
