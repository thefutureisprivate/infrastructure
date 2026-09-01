#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
pgbackrest_config="${repo_root}/Ansible/quadlets/pgbackrest.conf.j2"
pgbackrest_script="${repo_root}/Ansible/quadlets/mail-pgbackrest.sh.j2"
postgres_quadlet="${repo_root}/Ansible/quadlets/mail-postgres.container.j2"
postgres_roles="${repo_root}/Ansible/quadlets/mail-postgres-roles.sh.j2"
logical_script="${repo_root}/Ansible/quadlets/mail-backup-logical.sh.j2"
logical_quadlet="${repo_root}/Ansible/quadlets/mail-backup-logical.container.j2"
upload_script="${repo_root}/Ansible/quadlets/mail-backup-upload.sh.j2"
upload_quadlet="${repo_root}/Ansible/quadlets/mail-backup-logical-upload.container.j2"
logical_service="${repo_root}/Ansible/systemd/mail-backup-logical-run.service.j2"
backup_runner="${repo_root}/Ansible/quadlets/mail-backup-run.sh.j2"
backup_resources="${repo_root}/OpenTofu/backup.tf"
backup_variables="${repo_root}/OpenTofu/variables.tf"
quadlet_playbook="${repo_root}/Ansible/playbooks/quadlets.yml"
tofu_wrapper="${repo_root}/Scripts/tofu.sh"
image_deployer="${repo_root}/Scripts/deploy-mail-postgres-image.sh"
image_reference_helper="${repo_root}/Scripts/mail-postgres-backup-image-ref.py"
signing_key_generator="${repo_root}/Scripts/generate-backup-signing-key.sh"
offline_verifier="${repo_root}/Scripts/verify-logical-backup.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/mail-backup-lock.XXXXXX")
trap 'rm -rf -- "${test_root}"' EXIT HUP INT TERM

require_literal() {
  local literal=$1
  local file=$2
  grep -Fq -- "${literal}" "${file}" || {
    printf 'Missing backup invariant %q in %s.\n' "${literal}" "${file}" >&2
    exit 1
  }
}

for repository in 1 2; do
  require_literal "repo${repository}-cipher-type=aes-256-cbc" "${pgbackrest_config}"
  require_literal "PGBACKREST_REPO${repository}_CIPHER_PASS" "${postgres_quadlet}"
done
require_literal 'expire-auto=n' "${pgbackrest_config}"
require_literal 'pg1-user=postgres' "${pgbackrest_config}"
require_literal 'repo1-path=/stalwart/pgbackrest' "${pgbackrest_config}"
require_literal 'repo2-path=/stalwart/pgbackrest' "${pgbackrest_config}"
require_literal 'run_pgbackrest stanza-create' "${pgbackrest_script}"
require_literal 'run_pgbackrest check' "${pgbackrest_script}"
if grep -Eq -- '--repo=.*(stanza-create|check)|(stanza-create|check).*--repo=' "${pgbackrest_script}"; then
  printf 'pgBackRest stanza-create and check must operate across all configured repositories.\n' >&2
  exit 1
fi
require_literal 'run_pgbackrest --repo="${repository}" info' "${pgbackrest_script}"
require_literal 'run_pgbackrest --repo="${repository}" --type="${operation}" backup' "${pgbackrest_script}"

require_literal 'Environment=POSTGRES_USER=postgres' "${postgres_quadlet}"
require_literal 'Secret=mail-postgres-admin-password,type=mount,target=postgres-admin-password' "${postgres_quadlet}"
require_literal 'Secret=mail-postgres-dump-password,type=mount,target=postgres-dump-password' "${postgres_quadlet}"
require_literal 'Secret=mail-backup-hetzner-access-key,type=env,target=PGBACKREST_REPO1_S3_KEY' \
  "${postgres_quadlet}"
require_literal 'Secret=mail-backup-hetzner-secret-key,type=env,target=PGBACKREST_REPO1_S3_KEY_SECRET' \
  "${postgres_quadlet}"
require_literal 'ExecStartPost={{ quadlet_directory }}/mail-postgres-roles.sh' "${postgres_quadlet}"
require_literal 'NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS' "${postgres_roles}"
require_literal '--username=stalwart_dump' "${logical_script}"
require_literal 'openssl pkeyutl -sign -rawin' "${logical_script}"
require_literal 'openssl pkeyutl -verify -rawin -pubin' "${upload_script}"
require_literal 'The signature is the commit marker and is uploaded last.' "${upload_script}"
require_literal 'Image={{ mail_postgres_backup_image }}' "${postgres_quadlet}"
require_literal 'Pull=never' "${postgres_quadlet}"
require_literal 'podman load' "${image_deployer}"
require_literal 'sha256sum --check --status' "${image_deployer}"
require_literal '"${image_reference_helper}" --json' "${image_deployer}"
require_literal 'container_command=("${container_runtime}" --remote=false)' "${image_deployer}"
require_literal 'if [[ ${container_runtime##*/} != podman ]]; then' "${image_deployer}"
require_literal 'mail-postgres-image: ## Build the pinned backup image locally' \
  "${repo_root}/Makefile"
if rg -q 'Image=mail-postgres[.]build|name: "mail-postgres[.]build"[[:space:]]*$' \
  "${repo_root}/Ansible/quadlets" "${repo_root}/Ansible/inventory/group_vars/mail.yml"; then
  printf 'Production Quadlets must not build the PostgreSQL backup image on the VPS.\n' >&2
  exit 1
fi
require_literal "'name': 'mail-postgres.build'" \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"
if rg -q 'localhost/mail-postgres-backup:managed' \
  "${image_deployer}" "${repo_root}/Ansible/inventory/group_vars/mail.yml"; then
  printf 'The PostgreSQL backup image must not use a mutable deployment tag.\n' >&2
  exit 1
fi
expected_backup_image=$("${image_reference_helper}")
[[ ${expected_backup_image} =~ ^localhost/mail-postgres-backup:[0-9a-f]{64}$ ]]
require_literal 'mail-postgres-backup-image-ref.py' \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"
rendered_mail_variables=$(ANSIBLE_CONFIG="${repo_root}/Ansible/ansible.cfg" \
  ansible mail-01 -i "${repo_root}/Ansible/inventory/hosts.example.yml" \
    --connection local --module-name ansible.builtin.debug \
    --args 'var=mail_postgres_backup_image')
if ! grep -Fq -- \
  "\"mail_postgres_backup_image\": \"${expected_backup_image}\"" \
  <<<"${rendered_mail_variables}"; then
  printf 'Ansible did not render the content-addressed PostgreSQL backup image.\n' >&2
  exit 1
fi
unset rendered_mail_variables
cp -- "${repo_root}/Ansible/compose.yaml" "${test_root}/compose.yaml"
cp -- "${repo_root}/Ansible/quadlets/mail-postgres.Containerfile" \
  "${test_root}/mail-postgres.Containerfile"
test_image_before=$(MAIL_IMAGE_LOCK_FILE="${test_root}/compose.yaml" \
  MAIL_POSTGRES_CONTAINERFILE="${test_root}/mail-postgres.Containerfile" \
  "${image_reference_helper}")
printf '\n# Regression-test source change.\n' \
  >>"${test_root}/mail-postgres.Containerfile"
test_image_after=$(MAIL_IMAGE_LOCK_FILE="${test_root}/compose.yaml" \
  MAIL_POSTGRES_CONTAINERFILE="${test_root}/mail-postgres.Containerfile" \
  "${image_reference_helper}")
if [[ ${test_image_before} == "${test_image_after}" ]]; then
  printf 'PostgreSQL backup source changes must produce a new immutable image reference.\n' >&2
  exit 1
fi

require_literal 'Requires=gvisor-install.service mail-postgres.service' "${logical_quadlet}"
require_literal 'Network=mail-postgres.network' "${logical_quadlet}"
require_literal 'Network=mail-backup-egress.network' "${upload_quadlet}"
require_literal '--no-check-dest' "${upload_script}"
require_literal '--s3-no-head-object' "${upload_script}"
require_literal '--s3-no-head' "${upload_script}"
require_literal '--retries 1' "${upload_script}"
if grep -Eq 'RCLONE_CONFIG_|mail-pgbackrest-repo[12]-s3' "${logical_quadlet}"; then
  printf 'The backup signer must not receive object-storage credentials.\n' >&2
  exit 1
fi
if grep -Eq 'mail-postgres-dump-password|mail-backup-signing-private-key' "${upload_quadlet}"; then
  printf 'The backup uploader must not receive the database password or signing key.\n' >&2
  exit 1
fi
if grep -Eq 'mail-pgbackrest-repo2-s3' "${upload_quadlet}"; then
  printf 'The signed-backup uploader must not receive the B2 pgBackRest credentials.\n' >&2
  exit 1
fi
require_literal 'Secret=mail-backup-hetzner-access-key' "${upload_quadlet}"
require_literal 'Secret=mail-backup-b2-access-key' "${upload_quadlet}"
if grep -Fq 'mail-pgbackrest-init.service' "${logical_quadlet}"; then
  printf 'The cold logical backup must remain independent of hot-repository availability.\n' >&2
  exit 1
fi
if grep -Fq 'flock' "${logical_script}" || grep -Fq 'flock' "${pgbackrest_script}"; then
  printf 'Backup operations must acquire their shared lock in the host runner.\n' >&2
  exit 1
fi
require_literal 'flock --exclusive --wait 21600 9' "${backup_runner}"
require_literal 'systemctl start --wait mail-backup-logical-job.service' "${backup_runner}"
if [[ $(grep -Fc -- 'systemctl start --wait mail-backup-logical-upload.service' \
  "${backup_runner}") -ne 2 ]]; then
  printf 'The logical runner must flush staged data before and after signing.\n' >&2
  exit 1
fi
require_literal 'ExecStart={{ quadlet_directory }}/mail-backup-run.sh logical' "${logical_service}"
require_literal 'Unit=mail-backup-logical-run.service' \
  "${repo_root}/Ansible/systemd/mail-backup-logical.timer.j2"
if grep -Fq 'name: "mail-backup-logical.service"' \
  "${repo_root}/Ansible/inventory/group_vars/mail.yml"; then
  printf 'The host lock wrapper must not reuse the retired Quadlet service name.\n' >&2
  exit 1
fi

pg_dump_line=$(grep -n -m1 '^pg_dump' "${logical_script}" | cut -d: -f1)
age_line=$(grep -n -m1 '| age --encrypt' "${logical_script}" | cut -d: -f1)
if [[ -z ${pg_dump_line} || -z ${age_line} ]] || (( pg_dump_line >= age_line )); then
  printf 'The logical backup must stream pg_dump through age before staging ciphertext.\n' >&2
  exit 1
fi
if grep -Fq 'rclone' "${logical_script}"; then
  printf 'The signer must not be able to upload its signed artifacts.\n' >&2
  exit 1
fi
if grep -Eq 'mktemp|>[[:space:]]*[^|&[:space:]]*\.(dump|sql)([.[:space:]]|$)' "${logical_script}"; then
  printf 'The logical backup must not create a plaintext dump file.\n' >&2
  exit 1
fi

require_literal 'object_lock_enabled = true' "${backup_resources}"
require_literal 'mode = "COMPLIANCE"' "${backup_resources}"
require_literal 'storage_class = "GLACIER"' "${backup_resources}"
require_literal 'days          = 90' "${backup_resources}"
require_literal 'permission_set_names = ["ObjectStorageObjectsWrite"]' "${backup_resources}"
require_literal 'rotation_years = 1' "${backup_resources}"
require_literal 'expires_at         = time_rotating.mail_backup_scaleway_api_key[0].rotation_rfc3339' \
  "${backup_resources}"
require_literal 'create_before_destroy = true' "${backup_resources}"
if [[ $(grep -Fc -- 'organization_id = data.scaleway_account_project.mail_backup_cold[0].organization_id' \
  "${backup_resources}") -ne 2 ]]; then
  printf 'Scaleway IAM resources must derive their organization from the declared cold project.\n' >&2
  exit 1
fi
require_literal '"writeFiles",' "${backup_resources}"
if [[ $(grep -Fc -- 'count = var.mail_backup_storage_enabled ? 1 : 0' "${backup_resources}") -ne 5 ]]; then
  printf 'All five durable backup-storage resources must use the independent storage flag.\n' >&2
  exit 1
fi
if [[ $(grep -Fc -- 'count = local.mail_backup_runtime_enabled ? 1 : 0' "${backup_resources}") -ne 7 ]]; then
  printf 'The Scaleway project lookup, rotation clock, and five generated runtime resources must use the runtime/storage conjunction.\n' >&2
  exit 1
fi
if grep -Fq 'count = var.mail_backup_enabled' "${backup_resources}"; then
  printf 'Protected storage must not share the host runtime lifecycle flag.\n' >&2
  exit 1
fi
require_literal 'var.mail_backup_storage_enabled && var.mail_backup_age_recipient != ""' \
  "${backup_variables}"
if sed -n '/^check "mail_backup_inputs" {/,/^}/p' "${backup_resources}" \
  | grep -Fq 'mail_backup_enabled'; then
  printf 'Runtime prerequisites must be blocking variable validation, not a warning-only check.\n' >&2
  exit 1
fi
require_literal 'condition     = var.mail_backup_scaleway_region == "fr-par"' "${backup_variables}"
require_literal "mail_backup_scaleway_region == 'fr-par'" "${quadlet_playbook}"
if grep -Eq 'deleteFiles|s3:DeleteObject' "${backup_resources}"; then
  printf 'Generated restricted backup credentials must not receive object deletion.\n' >&2
  exit 1
fi
require_literal 'name_prefix = "stalwart/pgbackrest/"' "${backup_resources}"
require_literal 'name_prefix = "stalwart/signed-logical/"' "${backup_resources}"
if grep -Eq 'minio_s3_bucket_policy|mail_backup_hetzner_(pgbackrest|archive)_principal' \
  "${backup_resources}" "${backup_variables}"; then
  printf 'Hetzner must use the single dedicated-project credential without custom principals.\n' >&2
  exit 1
fi
require_literal 'mode=${1:-register}' "${signing_key_generator}"
require_literal 'if [[ ${mode} == register && ${have_existing} == true ]]; then' \
  "${signing_key_generator}"
require_literal 'old_id=$(register_public_key "${existing_public}")' \
  "${signing_key_generator}"
require_literal '{version: 2, signingKeyId: $signing_key_id,' "${logical_script}"
if grep -Fq -- 'A compromise of either side alone' \
  "${repo_root}/Documentation/Security.md"; then
  printf 'Security documentation still overstates signer/uploader independence.\n' >&2
  exit 1
fi

if [[ $(grep -Fc -- 'enforced = true' "${tofu_wrapper}") -ne 2 ]] \
  || grep -Fq -- 'enforced = false' "${tofu_wrapper}"; then
  printf 'OpenTofu state and plan encryption must never permit a plaintext fallback.\n' >&2
  exit 1
fi
require_literal 'method "aes_gcm" "infrastructure_state"' "${tofu_wrapper}"
require_literal 'iterations               = 600000' "${tofu_wrapper}"
require_literal 'export AWS_ACCESS_KEY_ID=${SCW_ACCESS_KEY}' "${tofu_wrapper}"
require_literal 'export AWS_SECRET_ACCESS_KEY=${SCW_SECRET_KEY}' "${tofu_wrapper}"
require_literal 'unset AWS_SESSION_TOKEN' "${tofu_wrapper}"

# Exercise initialization, idempotent registration, and explicit rotation
# without requiring the workstation's real SOPS identity.
fake_sops_bin="${test_root}/fake-sops-bin"
fake_sops_mail="${test_root}/mail.sops.yaml"
fake_keyring="${test_root}/public-keyring"
mkdir -p "${fake_sops_bin}"
cat >"${fake_sops_bin}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  decrypt)
    field=$3
    file=$4
    python3 -c '
import sys, yaml
field = "MAIL_BACKUP_SIGNING_PRIVATE_KEY" if "PRIVATE" in sys.argv[1] else "MAIL_BACKUP_SIGNING_PUBLIC_KEY"
with open(sys.argv[2], encoding="utf-8") as handle:
    print(yaml.safe_load(handle)[field], end="")
' "$field" "$file"
    ;;
  set)
    file=$3
    field=$4
    python3 -c '
import json, sys, yaml
field = "MAIL_BACKUP_SIGNING_PRIVATE_KEY" if "PRIVATE" in sys.argv[2] else "MAIL_BACKUP_SIGNING_PUBLIC_KEY"
value = json.load(sys.stdin)
with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
data[field] = value
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False)
' "$file" "$field"
    ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "${fake_sops_bin}/sops"
cat >"${fake_sops_mail}" <<'EOF'
MAIL_BACKUP_SIGNING_PRIVATE_KEY: replace-with-an-ed25519-private-key-in-pem-format
MAIL_BACKUP_SIGNING_PUBLIC_KEY: replace-with-the-matching-ed25519-public-key-in-pem-format
sops: {}
EOF
PATH="${fake_sops_bin}:${PATH}" SOPS_MAIL_FILE="${fake_sops_mail}" \
MAIL_BACKUP_SIGNING_KEYRING="${fake_keyring}" \
  "${signing_key_generator}" >/dev/null
initial_secret_hash=$(sha256sum "${fake_sops_mail}" | awk '{print $1}')
cp -- "${fake_sops_mail}" "${test_root}/valid-mail.sops.yaml"
PATH="${fake_sops_bin}:${PATH}" SOPS_MAIL_FILE="${fake_sops_mail}" \
MAIL_BACKUP_SIGNING_KEYRING="${fake_keyring}" \
  "${signing_key_generator}" >/dev/null
[[ $(sha256sum "${fake_sops_mail}" | awk '{print $1}') == "${initial_secret_hash}" ]]
[[ $(find "${fake_keyring}" -maxdepth 1 -type f -name '*.pem' | wc -l) -eq 1 ]]

# A partially damaged active pair is not an empty template. Preserve it for
# operator recovery instead of silently replacing its private authority.
python3 - "${fake_sops_mail}" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
data["MAIL_BACKUP_SIGNING_PUBLIC_KEY"] = "damaged-public-key"
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    yaml.safe_dump(data, handle, sort_keys=False)
PY
damaged_secret_hash=$(sha256sum "${fake_sops_mail}" | awk '{print $1}')
if PATH="${fake_sops_bin}:${PATH}" SOPS_MAIL_FILE="${fake_sops_mail}" \
   MAIL_BACKUP_SIGNING_KEYRING="${fake_keyring}" \
     "${signing_key_generator}" >/dev/null 2>&1; then
  printf 'Normal key registration replaced mismatched active signing material.\n' >&2
  exit 1
fi
[[ $(sha256sum "${fake_sops_mail}" | awk '{print $1}') == "${damaged_secret_hash}" ]]
cp -- "${test_root}/valid-mail.sops.yaml" "${fake_sops_mail}"

PATH="${fake_sops_bin}:${PATH}" SOPS_MAIL_FILE="${fake_sops_mail}" \
MAIL_BACKUP_SIGNING_KEYRING="${fake_keyring}" \
  "${signing_key_generator}" --rotate >/dev/null
[[ $(sha256sum "${fake_sops_mail}" | awk '{print $1}') != "${initial_secret_hash}" ]]
[[ $(find "${fake_keyring}" -maxdepth 1 -type f -name '*.pem' | wc -l) -eq 2 ]]

sed \
  -e "s#{{ quadlet_directory }}#${test_root}#g" \
  -e "s#/var/lib/mail-backup#${test_root}#g" \
  "${backup_runner}" >"${test_root}/mail-backup-run.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "$1" >"$MAIL_BACKUP_TEST_RESULT"' \
  >"${test_root}/mail-pgbackrest.sh"
chmod 0755 "${test_root}/mail-backup-run.sh" "${test_root}/mail-pgbackrest.sh"

exec 8<>"${test_root}/backup.lock"
flock --exclusive 8
set +e
MAIL_BACKUP_TEST_RESULT="${test_root}/operation" timeout 1 "${test_root}/mail-backup-run.sh" full
contention_status=$?
set -e
if [[ ${contention_status} -ne 124 || -e ${test_root}/operation ]]; then
  printf 'A contended backup did not remain queued behind the host lock.\n' >&2
  exit 1
fi
flock --unlock 8
MAIL_BACKUP_TEST_RESULT="${test_root}/operation" "${test_root}/mail-backup-run.sh" full
[[ $(<"${test_root}/operation") == full ]]

sed \
  -e "s#{{ quadlet_directory }}#${test_root}#g" \
  -e "s#/var/lib/mail-backup#${test_root}#g" \
  -e "s#/usr/bin/systemctl#${test_root}/systemctl#g" \
  "${backup_runner}" >"${test_root}/mail-backup-run-logical.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  ': >"$MAIL_BACKUP_TEST_STARTED"' \
  'while [[ ! -e $MAIL_BACKUP_TEST_RELEASE ]]; do sleep 0.05; done' \
  >"${test_root}/systemctl"
chmod 0755 "${test_root}/mail-backup-run-logical.sh" "${test_root}/systemctl"

MAIL_BACKUP_TEST_STARTED="${test_root}/logical-started" \
MAIL_BACKUP_TEST_RELEASE="${test_root}/logical-release" \
  timeout 5 "${test_root}/mail-backup-run-logical.sh" logical &
logical_runner_pid=$!
for _ in {1..40}; do
  [[ -e ${test_root}/logical-started ]] && break
  sleep 0.05
done
if [[ ! -e ${test_root}/logical-started ]]; then
  printf 'The host logical-backup wrapper did not start its inner service.\n' >&2
  exit 1
fi
if flock --exclusive --nonblock "${test_root}/backup.lock" true; then
  : >"${test_root}/logical-release"
  wait "${logical_runner_pid}" || true
  printf 'The host lock was released while the logical container job was active.\n' >&2
  exit 1
fi
: >"${test_root}/logical-release"
wait "${logical_runner_pid}"

# Exercise the creator/uploader trust split with a real Ed25519 signature and
# mocked pg_dump, age, and object-storage transport. The uploader must reject
# every tampered or misdirected set before the first network operation.
test_bin="${test_root}/bin"
staging="${test_root}/staging"
mkdir -p "${test_bin}" "${staging}"
cat >"${test_bin}/pg_dump" <<'EOF'
#!/usr/bin/env bash
if [[ ${MAIL_BACKUP_FAIL_DUMP:-0} == 1 ]]; then
  exit 9
fi
printf 'logical PostgreSQL archive fixture\n'
EOF
cat >"${test_bin}/age" <<'EOF'
#!/usr/bin/env bash
printf 'age-encrypted-fixture:'
cat
EOF
cat >"${test_bin}/rclone" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"${MAIL_BACKUP_UPLOAD_LOG}"
EOF
chmod 0755 "${test_bin}/pg_dump" "${test_bin}/age" "${test_bin}/rclone"
openssl genpkey -algorithm Ed25519 -out "${test_root}/signing-private.pem" >/dev/null 2>&1
openssl pkey -in "${test_root}/signing-private.pem" -pubout \
  -out "${test_root}/signing-public.pem" >/dev/null 2>&1
signing_key_id=$(openssl pkey -pubin -in "${test_root}/signing-public.pem" \
  -outform DER | sha256sum | awk '{print $1}')
keyring="${test_root}/keyring"
mkdir -p "${keyring}"
cp -- "${test_root}/signing-public.pem" "${keyring}/${signing_key_id}.pem"

run_creator() {
  PATH="${test_bin}:${PATH}" \
  MAIL_BACKUP_STAGING_DIRECTORY="${staging}" \
  MAIL_BACKUP_SIGNING_PRIVATE_KEY_FILE="${test_root}/signing-private.pem" \
  MAIL_BACKUP_SIGNING_PUBLIC_KEY_FILE="${test_root}/signing-public.pem" \
  MAIL_BACKUP_SCALEWAY_BUCKET=scaleway-fixture \
  MAIL_BACKUP_HETZNER_BUCKET=hetzner-fixture \
  MAIL_BACKUP_B2_BUCKET=b2-fixture \
  MAIL_BACKUP_AGE_RECIPIENT=age1fixture \
    bash "${logical_script}" >/dev/null
}

run_uploader() {
  PATH="${test_bin}:${PATH}" \
  MAIL_BACKUP_STAGING_DIRECTORY="${staging}" \
  MAIL_BACKUP_SIGNING_PUBLIC_KEY_FILE="${test_root}/signing-public.pem" \
  MAIL_BACKUP_SCALEWAY_BUCKET=scaleway-fixture \
  MAIL_BACKUP_HETZNER_BUCKET=hetzner-fixture \
  MAIL_BACKUP_B2_BUCKET=b2-fixture \
  MAIL_BACKUP_UPLOAD_LOG="${test_root}/uploads" \
    bash "${upload_script}"
}

run_creator
jq -e --arg key_id "${signing_key_id}" \
  '.version == 2 and .signingKeyId == $key_id' "${staging}/manifest.json" >/dev/null
"${offline_verifier}" "${staging}/backup.dump.age" "${staging}/manifest.json" \
  "${staging}/manifest.sig" "${keyring}" >/dev/null

# Legacy version-1 manifests did not carry a key ID. Every retained public key
# must still be tried so a later active-key rotation does not orphan archives.
jq 'del(.signingKeyId) | .version = 1' "${staging}/manifest.json" \
  >"${test_root}/legacy-manifest.json"
openssl pkeyutl -sign -rawin -inkey "${test_root}/signing-private.pem" \
  -in "${test_root}/legacy-manifest.json" -out "${test_root}/legacy-manifest.sig"
"${offline_verifier}" "${staging}/backup.dump.age" \
  "${test_root}/legacy-manifest.json" "${test_root}/legacy-manifest.sig" \
  "${keyring}" >/dev/null

run_uploader >/dev/null
if [[ $(wc -l <"${test_root}/uploads") -ne 9 ]]; then
  printf 'A complete backup did not upload exactly three artifacts to each provider.\n' >&2
  exit 1
fi
for remote in hetzner backblaze scaleway; do
  mapfile -t remote_uploads < <(awk -F '\t' -v prefix="${remote}:" '$3 ~ "^" prefix {print $3}' \
    "${test_root}/uploads")
  if [[ ${#remote_uploads[@]} -ne 3 \
      || ${remote_uploads[1]} != "${remote_uploads[0]}.manifest.json" \
      || ${remote_uploads[2]} != "${remote_uploads[0]}.manifest.sig" ]]; then
    printf 'Provider %s did not receive ciphertext, manifest, then signature commit marker.\n' \
      "${remote}" >&2
    exit 1
  fi
done
if find "${staging}" -mindepth 1 -print -quit | grep -q .; then
  printf 'Successfully uploaded staging data was not removed.\n' >&2
  exit 1
fi

: >"${test_root}/uploads"
run_creator
printf 'tampered' >>"${staging}/backup.dump.age"
if run_uploader >/dev/null 2>&1 || [[ -s ${test_root}/uploads ]]; then
  printf 'The uploader accepted ciphertext that did not match the signed digest.\n' >&2
  exit 1
fi
if [[ -e ${staging}/backup.dump.age || -e ${staging}/manifest.json || \
      -e ${staging}/manifest.sig ]]; then
  printf 'Invalid ciphertext staging was not quarantined.\n' >&2
  exit 1
fi

: >"${test_root}/uploads"
run_creator
jq '.destinations.scaleway.bucket = "attacker-bucket"' "${staging}/manifest.json" \
  >"${staging}/manifest.changed"
mv -- "${staging}/manifest.changed" "${staging}/manifest.json"
if run_uploader >/dev/null 2>&1 || [[ -s ${test_root}/uploads ]]; then
  printf 'The uploader accepted a manifest redirected to another bucket.\n' >&2
  exit 1
fi
if [[ -e ${staging}/backup.dump.age || -e ${staging}/manifest.json || \
      -e ${staging}/manifest.sig ]]; then
  printf 'Misdirected manifest staging was not quarantined.\n' >&2
  exit 1
fi

: >"${test_root}/uploads"
run_creator
printf 'tampered' >>"${staging}/manifest.sig"
if run_uploader >/dev/null 2>&1 || [[ -s ${test_root}/uploads ]]; then
  printf 'The uploader accepted an invalid manifest signature.\n' >&2
  exit 1
fi
if [[ -e ${staging}/backup.dump.age || -e ${staging}/manifest.json || \
      -e ${staging}/manifest.sig ]]; then
  printf 'Invalid signature staging was not quarantined.\n' >&2
  exit 1
fi

if MAIL_BACKUP_FAIL_DUMP=1 run_creator >/dev/null 2>&1; then
  printf 'The signer accepted a failed database dump.\n' >&2
  exit 1
fi
if [[ -e ${staging}/backup.dump.age || -e ${staging}/manifest.json || \
      -e ${staging}/manifest.sig ]]; then
  printf 'A failed database dump left active staging files behind.\n' >&2
  exit 1
fi

printf 'interrupted' >"${staging}/backup.dump.age"
if run_uploader >/dev/null 2>&1; then
  printf 'The uploader accepted an incomplete interrupted archive.\n' >&2
  exit 1
fi
run_creator
run_uploader >/dev/null

ln -s /etc/passwd "${staging}/backup.dump.age"
if run_creator >/dev/null 2>&1; then
  printf 'The signer accepted an attacker-controlled active staging path.\n' >&2
  exit 1
fi
if run_uploader >/dev/null 2>&1; then
  printf 'The uploader accepted an unsafe staging symlink.\n' >&2
  exit 1
fi

printf 'Encrypted mail backup invariants: OK\n'
