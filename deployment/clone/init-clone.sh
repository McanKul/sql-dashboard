#!/usr/bin/env bash
set -Eeuo pipefail

: "${POSTGRES_DB:?POSTGRES_DB tanimli olmali}"
: "${POSTGRES_USER:?POSTGRES_USER tanimli olmali}"
: "${CLONE_RUNNER_PASSWORD:?CLONE_RUNNER_PASSWORD tanimli olmali}"
: "${CLONE_SOURCE_ALIAS:?CLONE_SOURCE_ALIAS tanimli olmali}"

clone_marker="$(
  psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --tuples-only --no-align \
    --command="SELECT current_setting('advisor.validation_clone', true)"
)"
[[ "${clone_marker,,}" == "on" ]] || {
  echo "init-clone: advisor.validation_clone=on zorunludur" >&2
  exit 1
}

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=clone_database="$POSTGRES_DB" \
  --set=clone_admin="$POSTGRES_USER" \
  --set=runner_password="$CLONE_RUNNER_PASSWORD" <<'SQL'
SELECT format(
    'CREATE ROLE clone_runner LOGIN INHERIT PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4',
    :'runner_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clone_runner')
\gexec

ALTER ROLE clone_runner LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4 PASSWORD :'runner_password';
ALTER ROLE clone_runner RESET ALL;
ALTER ROLE clone_runner SET default_transaction_read_only = on;
ALTER ROLE clone_runner SET statement_timeout = '10s';
ALTER ROLE clone_runner SET lock_timeout = '1s';
ALTER ROLE clone_runner SET transaction_timeout = '15s';
ALTER ROLE clone_runner SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE clone_runner SET temp_file_limit = '256MB';
ALTER ROLE clone_runner SET row_security = on;
ALTER ROLE clone_runner SET jit = off;
ALTER ROLE clone_runner SET search_path = pg_catalog, public;

-- Membership options are security relevant on PostgreSQL 18. Remove every
-- existing grant (including grants from another grantor) before installing
-- the one role membership the runtime runner is allowed to retain.
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
SQL

template_restored=false
clone_template_dump="${CLONE_TEMPLATE_DUMP:-}"
if [[ -n "$clone_template_dump" ]]; then
  [[ -f "$clone_template_dump" ]] || {
    echo "init-clone: CLONE_TEMPLATE_DUMP normal bir archive dosyasi olmali" >&2
    exit 1
  }
  pg_restore \
    --exit-on-error \
    --single-transaction \
    --no-owner \
    --no-privileges \
    --no-tablespaces \
    --no-security-labels \
    --no-publications \
    --no-subscriptions \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    "$clone_template_dump"
  psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    --command='ANALYZE'
  template_restored=true
fi

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=clone_database="$POSTGRES_DB" \
  --set=clone_admin="$POSTGRES_USER" \
  --set=source_alias="$CLONE_SOURCE_ALIAS" \
  --set=template_restored="$template_restored" <<'SQL'
-- appdb bir veri kaynagi degil, onceden restore edilmis salt clone template'idir.
-- Runtime evaluator job database'lerini bu template'ten fiziksel olarak kopyalar.
REVOKE CONNECT, TEMPORARY ON DATABASE :"clone_database" FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE :"clone_database" FROM clone_runner;
ALTER DATABASE :"clone_database" WITH IS_TEMPLATE true;
ALTER DATABASE :"clone_database" SET advisor.validation_clone = 'on';

-- A restored archive can carry legacy PUBLIC ACLs. The runner never needs to
-- create schemas/objects, invoke dangerous routines, or contact foreign
-- servers. Generate every identifier/signature from catalogs so restored
-- object names can never become SQL text by concatenation.
SELECT format(
    'REVOKE CREATE ON SCHEMA %I FROM PUBLIC, clone_runner',
    namespace.nspname
)
FROM pg_catalog.pg_namespace AS namespace
WHERE left(namespace.nspname, 8) <> 'pg_temp_'
  AND left(namespace.nspname, 14) <> 'pg_toast_temp_'
ORDER BY namespace.oid
\gexec

WITH dangerous_routines AS (
    SELECT routine.oid,
           namespace.nspname,
           routine.proname,
           pg_catalog.pg_get_function_identity_arguments(routine.oid) AS identity_arguments
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    JOIN pg_catalog.pg_language AS language ON language.oid = routine.prolang
    WHERE routine.provolatile = 'v'
       OR routine.prosecdef
       OR routine.prokind = 'p'
       OR (
           namespace.nspname <> 'pg_catalog'
           AND namespace.nspname <> 'information_schema'
           AND language.lanname NOT IN ('sql', 'plpgsql')
       )
)
SELECT format(
    'REVOKE EXECUTE ON ROUTINE %I.%I(%s) FROM PUBLIC, clone_runner',
    nspname,
    proname,
    identity_arguments
)
FROM dangerous_routines
ORDER BY oid
\gexec

SELECT format(
    'REVOKE USAGE ON FOREIGN SERVER %I FROM PUBLIC, clone_runner',
    server.srvname
)
FROM pg_catalog.pg_foreign_server AS server
ORDER BY server.oid
\gexec

WITH dangerous_routines AS (
    SELECT routine.oid,
           routine.proacl,
           routine.proowner
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = routine.pronamespace
    JOIN pg_catalog.pg_language AS language ON language.oid = routine.prolang
    WHERE routine.provolatile = 'v'
       OR routine.prosecdef
       OR routine.prokind = 'p'
       OR (
           namespace.nspname <> 'pg_catalog'
           AND namespace.nspname <> 'information_schema'
           AND language.lanname NOT IN ('sql', 'plpgsql')
       )
)
SELECT NOT EXISTS (
    SELECT 1
    FROM dangerous_routines AS routine
    WHERE pg_catalog.has_function_privilege('clone_runner', routine.oid, 'EXECUTE')
       OR EXISTS (
           SELECT 1
           FROM pg_catalog.aclexplode(
               COALESCE(
                   routine.proacl,
                   pg_catalog.acldefault('f', routine.proowner)
               )
           ) AS privilege
           WHERE privilege.grantee = 0
             AND privilege.privilege_type = 'EXECUTE'
       )
) AS dangerous_routines_revoked
\gset
\if :dangerous_routines_revoked
\else
\echo Clone runner policy error: dangerous routine EXECUTE privilege remains
\quit 3
\endif

CREATE SCHEMA IF NOT EXISTS advisor_clone_meta AUTHORIZATION :"clone_admin";
REVOKE ALL ON SCHEMA advisor_clone_meta FROM PUBLIC;
CREATE TABLE IF NOT EXISTS advisor_clone_meta.template_manifest (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    initialized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    postgres_version text NOT NULL DEFAULT current_setting('server_version'),
    archive_restored boolean NOT NULL DEFAULT false,
    source_alias text NOT NULL,
    source_database_name text NOT NULL,
    source_ddl_executed boolean NOT NULL DEFAULT false CHECK (NOT source_ddl_executed),
    runner_policy_revision integer NOT NULL DEFAULT 1,
    dangerous_routines_revoked boolean NOT NULL DEFAULT true
);
ALTER TABLE advisor_clone_meta.template_manifest
  ADD COLUMN IF NOT EXISTS runner_policy_revision integer;
ALTER TABLE advisor_clone_meta.template_manifest
  ADD COLUMN IF NOT EXISTS dangerous_routines_revoked boolean;
ALTER TABLE advisor_clone_meta.template_manifest
  ADD COLUMN IF NOT EXISTS source_alias text;
ALTER TABLE advisor_clone_meta.template_manifest
  ADD COLUMN IF NOT EXISTS source_database_name text;
UPDATE advisor_clone_meta.template_manifest
SET runner_policy_revision = 1,
    dangerous_routines_revoked = true,
    source_alias = :'source_alias',
    source_database_name = :'clone_database'
WHERE runner_policy_revision IS DISTINCT FROM 1
   OR dangerous_routines_revoked IS DISTINCT FROM true
   OR source_alias IS DISTINCT FROM :'source_alias'
   OR source_database_name IS DISTINCT FROM :'clone_database';
ALTER TABLE advisor_clone_meta.template_manifest
  ALTER COLUMN runner_policy_revision SET DEFAULT 1,
  ALTER COLUMN runner_policy_revision SET NOT NULL,
  ALTER COLUMN dangerous_routines_revoked SET DEFAULT true,
  ALTER COLUMN dangerous_routines_revoked SET NOT NULL,
  ALTER COLUMN source_alias SET NOT NULL,
  ALTER COLUMN source_database_name SET NOT NULL;
INSERT INTO advisor_clone_meta.template_manifest(
    singleton,
    archive_restored,
    source_alias,
    source_database_name,
    runner_policy_revision,
    dangerous_routines_revoked
)
VALUES (
    true,
    :'template_restored'::boolean,
    :'source_alias',
    :'clone_database',
    1,
    true
)
ON CONFLICT (singleton) DO UPDATE
SET initialized_at = EXCLUDED.initialized_at,
    postgres_version = EXCLUDED.postgres_version,
    archive_restored = EXCLUDED.archive_restored,
    source_alias = EXCLUDED.source_alias,
    source_database_name = EXCLUDED.source_database_name,
    source_ddl_executed = false,
    runner_policy_revision = EXCLUDED.runner_policy_revision,
    dangerous_routines_revoked = EXCLUDED.dangerous_routines_revoked;
SQL
