#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
postgres_image=$(sed -n '/^  postgres:/,/^  [a-z]/s/^[[:space:]]*image: "\([^"]*\)"/\1/p' \
  "${repo_root}/Ansible/compose.yaml")

container_engine=${CONTAINER_ENGINE:-}
if [[ -z ${container_engine} ]]; then
  if command -v podman >/dev/null 2>&1; then
    container_engine=podman
  elif command -v docker >/dev/null 2>&1; then
    container_engine=docker
  else
    printf 'PostgreSQL role integration: skipped (container engine unavailable)\n'
    exit 0
  fi
fi
container() {
  "${container_engine}" "$@"
}

image_available=false
case "${container_engine}" in
  podman)
    container image exists "${postgres_image}" && image_available=true
    ;;
  docker)
    container image inspect "${postgres_image}" >/dev/null 2>&1 && image_available=true
    ;;
  *)
    printf 'Unsupported container engine: %s\n' "${container_engine}" >&2
    exit 2
    ;;
esac
if [[ ${image_available} == false ]]; then
  if [[ ${POSTGRES_ROLES_PULL:-0} != 1 ]]; then
    printf 'PostgreSQL role integration: skipped (pinned image unavailable)\n'
    exit 0
  fi
  container pull "${postgres_image}" >/dev/null
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/postgres-roles.XXXXXX")
fresh_container="postgres-roles-fresh-$$"
legacy_container="postgres-roles-legacy-$$"
cleanup() {
  container rm --force "${fresh_container}" "${legacy_container}" >/dev/null 2>&1 || true
  rm -rf -- "${test_root}"
}
trap cleanup EXIT HUP INT TERM

admin_password='admin-test-password-0123456789abcdef'
app_password='application-test-password-0123456789'
dump_password='dump-test-password-0123456789abcdef'
printf '%s' "${admin_password}" >"${test_root}/admin-password"
printf '%s' "${app_password}" >"${test_root}/app-password"
printf '%s' "${dump_password}" >"${test_root}/dump-password"
chmod 0644 "${test_root}"/*-password

container_arguments=(
  --detach
  --network=none
  --tmpfs /var/lib/postgresql:rw
  --volume "${repo_root}/Ansible/quadlets/mail-postgres-roles.sh.j2:/usr/local/sbin/mail-postgres-roles:ro"
  --volume "${test_root}/admin-password:/run/secrets/postgres-admin-password:ro"
  --volume "${test_root}/app-password:/run/secrets/postgres-password:ro"
  --volume "${test_root}/dump-password:/run/secrets/postgres-dump-password:ro"
  --env POSTGRES_DB=stalwart
  --env 'POSTGRES_INITDB_ARGS=--auth-local=trust --auth-host=scram-sha-256'
)
if [[ ${container_engine} == podman ]]; then
  container_arguments+=(--security-opt label=disable)
fi

wait_for_postgres() {
  local container=$1
  for _ in {1..60}; do
    if command "${container_engine}" exec "${container}" pg_isready --host=127.0.0.1 \
      --username=postgres --dbname=stalwart >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  command "${container_engine}" logs "${container}" >&2
  return 1
}

reconcile_and_verify() {
  local container=$1
  local role_state

  command "${container_engine}" exec --user 70 "${container}" bash /usr/local/sbin/mail-postgres-roles inside
  command "${container_engine}" exec --user 70 "${container}" bash /usr/local/sbin/mail-postgres-roles inside

  role_state=$(command "${container_engine}" exec --user 70 "${container}" \
    psql --no-password --no-psqlrc --username=postgres --dbname=stalwart \
      --tuples-only --no-align --field-separator='|' --command="
        SELECT
          (SELECT rolname = 'postgres' AND rolsuper FROM pg_catalog.pg_roles WHERE oid = 10),
          (SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
             FROM pg_catalog.pg_roles WHERE rolname = 'stalwart'),
          (SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls
             FROM pg_catalog.pg_roles WHERE rolname = 'stalwart_dump'),
          pg_catalog.pg_has_role('stalwart_dump', 'pg_read_all_data', 'member'),
          NOT EXISTS (
            SELECT
            FROM pg_catalog.pg_auth_members AS membership
            JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
            WHERE member_role.rolname = 'stalwart'
          ),
          NOT EXISTS (
            SELECT
            FROM pg_catalog.pg_auth_members AS membership
            JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
            JOIN pg_catalog.pg_roles AS member_role ON member_role.oid = membership.member
            WHERE member_role.rolname = 'stalwart_dump'
              AND granted_role.rolname <> 'pg_read_all_data'
          ),
          (SELECT pg_catalog.pg_get_userbyid(datdba) = 'postgres'
             FROM pg_catalog.pg_database WHERE datname = 'stalwart'),
          (SELECT pg_catalog.pg_get_userbyid(nspowner) = 'postgres'
             FROM pg_catalog.pg_namespace WHERE nspname = 'public'),
          NOT pg_catalog.has_database_privilege('stalwart', 'stalwart', 'CREATE');
      ")
  [[ ${role_state} == 't|f|f|t|t|t|t|t|t' ]]

  command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-password)
    psql --host=127.0.0.1 --username=stalwart --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="
        CREATE TABLE role_test (value integer);
        INSERT INTO role_test VALUES (1);
        CREATE FUNCTION public.dump_write_bypass()
        RETURNS void
        LANGUAGE SQL
        SECURITY DEFINER
        SET search_path = pg_catalog
        AS '\''INSERT INTO public.role_test VALUES (99)'\'';
      "
  '
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-password)
    psql --host=127.0.0.1 --username=stalwart --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="COPY (SELECT 1) TO PROGRAM '\''true'\''"
  ' >/dev/null 2>&1; then
    printf 'The Stalwart application role executed a server-side program.\n' >&2
    exit 1
  fi
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-password)
    psql --host=127.0.0.1 --username=stalwart --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="ALTER SYSTEM SET archive_command = '\''true'\''"
  ' >/dev/null 2>&1; then
    printf 'The Stalwart application role changed server-wide configuration.\n' >&2
    exit 1
  fi
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-password)
    psql --host=127.0.0.1 --username=stalwart --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="SELECT pg_read_binary_file('\''/proc/1/environ'\'')"
  ' >/dev/null 2>&1; then
    printf 'The Stalwart application role read the PostgreSQL process environment.\n' >&2
    exit 1
  fi

  command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-dump-password)
    psql --host=127.0.0.1 --username=stalwart_dump --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="SELECT * FROM role_test" >/dev/null
    pg_dump --host=127.0.0.1 --username=stalwart_dump --dbname=stalwart \
      --schema-only --no-password >/dev/null
  '
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-dump-password)
    psql --host=127.0.0.1 --username=stalwart_dump --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="INSERT INTO role_test VALUES (2)"
  ' >/dev/null 2>&1; then
    printf 'The logical-dump role modified application data.\n' >&2
    exit 1
  fi
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-dump-password)
    psql --host=127.0.0.1 --username=stalwart_dump --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="SELECT public.dump_write_bypass()"
  ' >/dev/null 2>&1; then
    printf 'The logical-dump role wrote through an application-owned routine.\n' >&2
    exit 1
  fi

  # Reconciliation must also remove an explicit routine grant left by an old
  # migration, not only PostgreSQL's default PUBLIC execute privilege.
  command "${container_engine}" exec --user 70 "${container}" \
    psql --no-password --no-psqlrc --username=postgres --dbname=stalwart \
      --set=ON_ERROR_STOP=1 \
      --command='GRANT EXECUTE ON FUNCTION public.dump_write_bypass() TO stalwart_dump, pg_read_all_data'
  command "${container_engine}" exec --user 70 "${container}" \
    bash /usr/local/sbin/mail-postgres-roles inside
  if command "${container_engine}" exec --user 70 "${container}" sh -ceu '
    export PGPASSWORD=$(cat /run/secrets/postgres-dump-password)
    psql --host=127.0.0.1 --username=stalwart_dump --dbname=stalwart --no-psqlrc \
      --set=ON_ERROR_STOP=1 --command="SELECT public.dump_write_bypass()"
  ' >/dev/null 2>&1; then
    printf 'The logical-dump role retained an application-routine grant.\n' >&2
    exit 1
  fi
}

container run --name "${fresh_container}" \
  "${container_arguments[@]}" \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres-admin-password \
  "${postgres_image}" >/dev/null
wait_for_postgres "${fresh_container}"
reconcile_and_verify "${fresh_container}"

container run --name "${legacy_container}" \
  "${container_arguments[@]}" \
  --env POSTGRES_USER=stalwart \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password \
  "${postgres_image}" >/dev/null
wait_for_postgres "${legacy_container}"
container exec --user 70 "${legacy_container}" \
  psql --no-password --username=stalwart --dbname=stalwart --no-psqlrc \
    --set=ON_ERROR_STOP=1 --command='
      CREATE TABLE legacy_owned (value integer);
      CREATE TABLE legacy_serial (id serial PRIMARY KEY);
      CREATE TABLE legacy_identity (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY);
      CREATE SEQUENCE legacy_standalone;
      CREATE TYPE legacy_range AS RANGE (subtype = integer);
      CREATE TABLE legacy_range_value (value legacy_range);
    ' >/dev/null
reconcile_and_verify "${legacy_container}"
container exec --user 70 "${legacy_container}" sh -ceu '
  export PGPASSWORD=$(cat /run/secrets/postgres-password)
  psql --host=127.0.0.1 --username=stalwart --dbname=stalwart --no-psqlrc \
    --set=ON_ERROR_STOP=1 --command="
      INSERT INTO legacy_owned VALUES (1);
      INSERT INTO legacy_serial DEFAULT VALUES;
      INSERT INTO legacy_identity DEFAULT VALUES;
      SELECT nextval('\''legacy_standalone'\'');
      INSERT INTO legacy_range_value VALUES ('\''[1,2)'\'');
    " >/dev/null
'

printf 'PostgreSQL role separation and legacy migration: OK\n'
