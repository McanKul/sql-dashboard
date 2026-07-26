#!/usr/bin/env bash
set -Eeuo pipefail

# Docker's initdb hooks only run for an empty PGDATA.  This health-gated helper
# reconciles login secrets for an existing volume before dependent services are
# allowed to start.  It deliberately connects through the local Unix socket so
# rotating the administrator password cannot lock the reconciler out.
umask 077

profile="${1:-}"
psql_bin="${ADVISOR_RECONCILE_PSQL_BIN:-psql}"
socket_dir="${ADVISOR_RECONCILE_SOCKET_DIR:-/var/run/postgresql}"
port="${PGPORT:-5432}"
# Bump when the desired role policy changes even if the secret set and marker
# file format do not. Existing volumes must run the new reconciliation once
# instead of accepting a state produced by an older image.
policy_revision="4"

fail() {
  printf 'Role reconciliation error: %s\n' "$1" >&2
  exit 1
}

require_secret() {
  local variable_name="$1"
  [[ -n "${!variable_name-}" ]] \
    || fail "${variable_name} must be set and non-empty"
}

reject_known_password() {
  local variable_name="$1"
  case "${!variable_name}" in
    change-me-*|advisor_dev_*)
      fail "${variable_name} must not use a documented placeholder or legacy development password"
      ;;
  esac
}

case "$profile" in
  source)
    password_variables=(
      POSTGRES_PASSWORD
      POWA_COLLECTOR_PASSWORD
      ADVISOR_EVALUATOR_PASSWORD
      ADVISOR_JOIN_SOURCE_PASSWORD
      WORKLOAD_DB_PASSWORD
    )
    state_roles="'powa_collector', 'advisor_evaluator', 'advisor_join_reader', 'advisor_workload_login'"
    database="${POSTGRES_DB:-}"
    ;;
  repository)
    password_variables=(
      POSTGRES_PASSWORD
      POWA_COLLECTOR_PASSWORD
      ADVISOR_API_PASSWORD
      ADVISOR_JOIN_REPOSITORY_PASSWORD
    )
    state_roles="'powa_collector', 'advisor_api', 'advisor_join_ingest'"
    database="${POSTGRES_DB:-}"
    ;;
  clone)
    password_variables=(
      POSTGRES_PASSWORD
      POWA_COLLECTOR_PASSWORD
      ADVISOR_EVALUATOR_PASSWORD
      ADVISOR_JOIN_SOURCE_PASSWORD
      CLONE_RUNNER_PASSWORD
    )
    state_roles="'powa_collector', 'advisor_evaluator', 'advisor_join_reader', 'clone_runner'"
    # appdb is deliberately converted into a restricted template.  Cluster
    # roles can be reconciled from the always-present postgres database.
    database="postgres"
    ;;
  *)
    fail "profile must be source, repository, or clone"
    ;;
esac

: "${PGDATA:?PGDATA must be set}"
: "${POSTGRES_USER:?POSTGRES_USER must be set}"
[[ -n "$database" ]] || fail "POSTGRES_DB must be set and non-empty"
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || fail "PGPORT must be a valid port"
(( port <= 65535 )) || fail "PGPORT must be a valid port"
[[ -d "$PGDATA" && -w "$PGDATA" ]] || fail "PGDATA must be a writable directory"
command -v "$psql_bin" >/dev/null 2>&1 \
  || fail "psql executable is unavailable"

for password_variable in "${password_variables[@]}"; do
  require_secret "$password_variable"
  # source/repository volumes persist. The clone profile is disposable tmpfs,
  # internal-only, and may retain documented demo defaults for local testing.
  if [[ "$profile" != "clone" ]]; then
    reject_known_password "$password_variable"
  fi
done

if command -v sha256sum >/dev/null 2>&1; then
  hash_stream() { sha256sum | { read -r digest _; printf '%s\n' "$digest"; }; }
elif command -v shasum >/dev/null 2>&1; then
  hash_stream() { shasum -a 256 | { read -r digest _; printf '%s\n' "$digest"; }; }
else
  fail "sha256sum or shasum is required"
fi

marker_path="${ADVISOR_RECONCILE_MARKER_DIR:-$PGDATA}/.advisor-role-passwords-${profile}.v1"
marker_version=""
marker_salt=""
marker_desired=""
marker_state=""

if [[ -r "$marker_path" ]]; then
  while IFS='=' read -r marker_key marker_value; do
    case "$marker_key" in
      version) marker_version="$marker_value" ;;
      salt) marker_salt="$marker_value" ;;
      desired) marker_desired="$marker_value" ;;
      state) marker_state="$marker_value" ;;
    esac
  done < "$marker_path"
fi

if [[ "$marker_version" != 1 \
      || ! "$marker_salt" =~ ^[0-9a-f]{64}$ \
      || ! "$marker_desired" =~ ^[0-9a-f]{64}$ \
      || ! "$marker_state" =~ ^[0-9a-f]{64}$ ]]; then
  marker_version=""
  marker_salt="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
  marker_desired=""
  marker_state=""
fi

desired_fingerprint="$({
  printf '%s\0' "advisor-role-reconciler-policy-v${policy_revision}" \
    "$marker_salt" "$profile" "$POSTGRES_USER"
  for password_variable in "${password_variables[@]}"; do
    printf '%s\0' "$password_variable" "${!password_variable}"
  done
} | hash_stream)"

psql_args=(
  -X
  -q
  --set=ON_ERROR_STOP=1
  --host="$socket_dir"
  --port="$port"
  --username="$POSTGRES_USER"
  --dbname="$database"
)

# Keep this internal health probe out of source telemetry.  Prefix rather than
# export so the setting cannot leak into the remaining healthcheck commands.
reconcile_pgoptions="${PGOPTIONS:+${PGOPTIONS} }-c pg_stat_statements.track=none"
run_psql() {
  PGOPTIONS="$reconcile_pgoptions" \
    PGAPPNAME="advisor-role-reconciler" \
    "$psql_bin" "${psql_args[@]}" "$@"
}

role_state_fingerprint() {
  run_psql --tuples-only --no-align \
    --command="SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'rolname', auth.rolname,
      'rolpassword', auth.rolpassword,
      'rolvaliduntil', auth.rolvaliduntil,
      'rolsuper', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolsuper END,
      'rolinherit', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolinherit END,
      'rolcreatedb', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolcreatedb END,
      'rolcreaterole', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolcreaterole END,
      'rolcanlogin', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolcanlogin END,
      'rolreplication', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolreplication END,
      'rolbypassrls', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolbypassrls END,
      'rolconnlimit', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE auth.rolconnlimit END,
      'rolmemberships', CASE WHEN auth.rolname <> 'clone_runner' THEN NULL ELSE (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'role', granted_role.rolname,
            'grantor', grantor.rolname,
            'admin_option', membership.admin_option,
            'inherit_option', membership.inherit_option,
            'set_option', membership.set_option
          )
          ORDER BY granted_role.rolname, grantor.rolname
        )
        FROM pg_catalog.pg_auth_members AS membership
        JOIN pg_catalog.pg_authid AS granted_role ON granted_role.oid = membership.roleid
        JOIN pg_catalog.pg_authid AS grantor ON grantor.oid = membership.grantor
        WHERE membership.member = auth.oid
      ) END,
      'rolconfig', CASE WHEN auth.rolname = CURRENT_USER THEN NULL ELSE (
        SELECT pg_catalog.jsonb_object_agg(
          COALESCE(db.datname, '*'), setting.setconfig
          ORDER BY COALESCE(db.datname, '*')
        )
        FROM pg_catalog.pg_db_role_setting AS setting
        LEFT JOIN pg_catalog.pg_database AS db ON db.oid = setting.setdatabase
        WHERE setting.setrole = auth.oid
      ) END
    ) ORDER BY auth.rolname), '[]'::pg_catalog.jsonb)::text
    FROM pg_catalog.pg_authid AS auth
    WHERE auth.rolname IN (CURRENT_USER, ${state_roles})" \
    | hash_stream
}

current_state="$(role_state_fingerprint)"

write_atomic() {
  local destination="$1"
  local content="$2"
  local temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$destination"
}

if [[ "$marker_desired" == "$desired_fingerprint" && "$marker_state" == "$current_state" ]]; then
  exit 0
fi

case "$profile" in
  source)
    run_psql <<'SQL'
\set ON_ERROR_STOP on
\getenv admin_password POSTGRES_PASSWORD
\getenv collector_password POWA_COLLECTOR_PASSWORD
\getenv evaluator_password ADVISOR_EVALUATOR_PASSWORD
\getenv join_password ADVISOR_JOIN_SOURCE_PASSWORD
\getenv workload_password WORKLOAD_DB_PASSWORD
BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_parameter_max_length_on_error = 0;
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'powa_collector')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_evaluator')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_join_reader')
   AS required_roles_present \gset
\if :required_roles_present
SELECT format('ALTER ROLE %I PASSWORD %L VALID UNTIL ''infinity''', CURRENT_USER, :'admin_password') \gexec
ALTER ROLE powa_collector LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD :'collector_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_evaluator LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2 PASSWORD :'evaluator_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_join_reader LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2 PASSWORD :'join_password' VALID UNTIL 'infinity';
SELECT format(
    'ALTER ROLE advisor_workload_login LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 70 PASSWORD %L VALID UNTIL ''infinity''',
    :'workload_password'
)
WHERE EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_workload_login'
)
\gexec
SELECT format('ALTER ROLE %I IN DATABASE %I RESET ALL', auth.rolname, db.datname)
FROM pg_catalog.pg_db_role_setting AS setting
JOIN pg_catalog.pg_authid AS auth ON auth.oid = setting.setrole
JOIN pg_catalog.pg_database AS db ON db.oid = setting.setdatabase
WHERE auth.rolname IN ('powa_collector', 'advisor_evaluator', 'advisor_join_reader', 'advisor_workload_login')
  AND setting.setdatabase <> 0
\gexec
ALTER ROLE powa_collector RESET ALL;
ALTER ROLE advisor_evaluator RESET ALL;
ALTER ROLE advisor_join_reader RESET ALL;
SELECT 'ALTER ROLE advisor_workload_login RESET ALL'
WHERE EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_workload_login'
)
\gexec
-- Internal observers emit COPY/EXPLAIN/outbox utility text. Some of those
-- statements contain literals that pg_stat_statements cannot normalize, so
-- tracking the observers eventually evicts the application statements they
-- are meant to preserve. These defaults affect only new observer sessions and
-- remain part of the drift-reconciled role state.
ALTER ROLE powa_collector SET pg_stat_statements.track = 'none';
ALTER ROLE powa_collector SET pg_stat_kcache.track = 'none';
ALTER ROLE powa_collector SET pg_qualstats.enabled = off;
ALTER ROLE advisor_evaluator SET pg_stat_statements.track = 'none';
ALTER ROLE advisor_evaluator SET pg_stat_kcache.track = 'none';
ALTER ROLE advisor_evaluator SET pg_qualstats.enabled = off;
ALTER ROLE advisor_join_reader SET pg_stat_statements.track = 'none';
ALTER ROLE advisor_join_reader SET pg_stat_kcache.track = 'none';
ALTER ROLE advisor_join_reader SET pg_qualstats.enabled = off;
ALTER ROLE advisor_evaluator SET default_transaction_read_only = on;
ALTER ROLE advisor_evaluator SET statement_timeout = '2s';
ALTER ROLE advisor_evaluator SET lock_timeout = '250ms';
ALTER ROLE advisor_evaluator SET idle_in_transaction_session_timeout = '3s';
COMMIT;
\else
ROLLBACK;
\echo Role reconciliation error: required source roles are missing
\quit 3
\endif
SQL
    ;;
  repository)
    run_psql <<'SQL'
\set ON_ERROR_STOP on
\getenv admin_password POSTGRES_PASSWORD
\getenv collector_password POWA_COLLECTOR_PASSWORD
\getenv api_password ADVISOR_API_PASSWORD
\getenv join_password ADVISOR_JOIN_REPOSITORY_PASSWORD
BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_parameter_max_length_on_error = 0;
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'powa_collector')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_api')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_join_ingest')
   AS required_roles_present \gset
\if :required_roles_present
SELECT format('ALTER ROLE %I PASSWORD %L VALID UNTIL ''infinity''', CURRENT_USER, :'admin_password') \gexec
ALTER ROLE powa_collector LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD :'collector_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_api LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD :'api_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_join_ingest LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2 PASSWORD :'join_password' VALID UNTIL 'infinity';
SELECT format('ALTER ROLE %I IN DATABASE %I RESET ALL', auth.rolname, db.datname)
FROM pg_catalog.pg_db_role_setting AS setting
JOIN pg_catalog.pg_authid AS auth ON auth.oid = setting.setrole
JOIN pg_catalog.pg_database AS db ON db.oid = setting.setdatabase
WHERE auth.rolname IN ('powa_collector', 'advisor_api', 'advisor_join_ingest')
  AND setting.setdatabase <> 0
\gexec
ALTER ROLE powa_collector RESET ALL;
ALTER ROLE advisor_api RESET ALL;
ALTER ROLE advisor_join_ingest RESET ALL;
COMMIT;
\else
ROLLBACK;
\echo Role reconciliation error: required repository roles are missing
\quit 3
\endif
SQL
    ;;
  clone)
    run_psql <<'SQL'
\set ON_ERROR_STOP on
\getenv admin_password POSTGRES_PASSWORD
\getenv collector_password POWA_COLLECTOR_PASSWORD
\getenv evaluator_password ADVISOR_EVALUATOR_PASSWORD
\getenv join_password ADVISOR_JOIN_SOURCE_PASSWORD
\getenv runner_password CLONE_RUNNER_PASSWORD
BEGIN;
SET LOCAL password_encryption = 'scram-sha-256';
SET LOCAL log_statement = 'none';
SET LOCAL log_min_error_statement = 'panic';
SET LOCAL log_parameter_max_length_on_error = 0;
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = CURRENT_USER)
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'powa_collector')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_evaluator')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'advisor_join_reader')
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'clone_runner')
   AS required_roles_present \gset
\if :required_roles_present
SELECT format('ALTER ROLE %I PASSWORD %L VALID UNTIL ''infinity''', CURRENT_USER, :'admin_password') \gexec
ALTER ROLE powa_collector LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT -1 PASSWORD :'collector_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_evaluator LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2 PASSWORD :'evaluator_password' VALID UNTIL 'infinity';
ALTER ROLE advisor_join_reader LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2 PASSWORD :'join_password' VALID UNTIL 'infinity';
ALTER ROLE clone_runner LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4 PASSWORD :'runner_password' VALID UNTIL 'infinity';
SELECT format(
    'REVOKE %I FROM clone_runner GRANTED BY %I CASCADE',
    granted_role.rolname,
    grantor.rolname
)
FROM pg_catalog.pg_auth_members AS membership
JOIN pg_catalog.pg_roles AS granted_role ON granted_role.oid = membership.roleid
JOIN pg_catalog.pg_roles AS grantor ON grantor.oid = membership.grantor
WHERE membership.member = 'clone_runner'::pg_catalog.regrole
\gexec
GRANT pg_read_all_data TO clone_runner
  WITH INHERIT TRUE, SET FALSE, ADMIN FALSE;
SELECT format('ALTER ROLE %I IN DATABASE %I RESET ALL', auth.rolname, db.datname)
FROM pg_catalog.pg_db_role_setting AS setting
JOIN pg_catalog.pg_authid AS auth ON auth.oid = setting.setrole
JOIN pg_catalog.pg_database AS db ON db.oid = setting.setdatabase
WHERE auth.rolname IN ('powa_collector', 'advisor_evaluator', 'advisor_join_reader', 'clone_runner')
  AND setting.setdatabase <> 0
\gexec
ALTER ROLE powa_collector RESET ALL;
ALTER ROLE advisor_evaluator RESET ALL;
ALTER ROLE advisor_join_reader RESET ALL;
ALTER ROLE clone_runner RESET ALL;
ALTER ROLE powa_collector SET pg_stat_statements.track = 'none';
ALTER ROLE powa_collector SET pg_stat_kcache.track = 'none';
ALTER ROLE powa_collector SET pg_qualstats.enabled = off;
ALTER ROLE advisor_evaluator SET pg_stat_statements.track = 'none';
ALTER ROLE advisor_evaluator SET pg_stat_kcache.track = 'none';
ALTER ROLE advisor_evaluator SET pg_qualstats.enabled = off;
ALTER ROLE advisor_join_reader SET pg_stat_statements.track = 'none';
ALTER ROLE advisor_join_reader SET pg_stat_kcache.track = 'none';
ALTER ROLE advisor_join_reader SET pg_qualstats.enabled = off;
ALTER ROLE advisor_evaluator SET default_transaction_read_only = on;
ALTER ROLE advisor_evaluator SET statement_timeout = '2s';
ALTER ROLE advisor_evaluator SET lock_timeout = '250ms';
ALTER ROLE advisor_evaluator SET idle_in_transaction_session_timeout = '3s';
ALTER ROLE clone_runner SET default_transaction_read_only = on;
ALTER ROLE clone_runner SET statement_timeout = '10s';
ALTER ROLE clone_runner SET lock_timeout = '1s';
ALTER ROLE clone_runner SET transaction_timeout = '15s';
ALTER ROLE clone_runner SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE clone_runner SET temp_file_limit = '256MB';
ALTER ROLE clone_runner SET row_security = on;
ALTER ROLE clone_runner SET jit = off;
ALTER ROLE clone_runner SET search_path = pg_catalog, public;
COMMIT;
\else
ROLLBACK;
\echo Role reconciliation error: required clone roles are missing
\quit 3
\endif
SQL
    ;;
esac

# Never publish a marker for a partial/rolled-back transaction.  Re-read the
# committed verifier/privilege state first, then atomically replace the 0600
# marker.  Every health probe still reads this cheap state fingerprint so
# in-process privilege drift cannot hide behind a startup-only cache.
current_state="$(role_state_fingerprint)"
write_atomic "$marker_path" "version=1
salt=${marker_salt}
desired=${desired_fingerprint}
state=${current_state}"
