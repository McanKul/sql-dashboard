#!/usr/bin/env bash
set -Eeuo pipefail

: "${POSTGRES_DB:?POSTGRES_DB tanimli olmali}"
: "${POSTGRES_USER:?POSTGRES_USER tanimli olmali}"
: "${CLONE_RUNNER_PASSWORD:?CLONE_RUNNER_PASSWORD tanimli olmali}"

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
    'CREATE ROLE clone_runner LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 4',
    :'runner_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'clone_runner')
\gexec

ALTER ROLE clone_runner PASSWORD :'runner_password';
ALTER ROLE clone_runner SET default_transaction_read_only = on;
ALTER ROLE clone_runner SET statement_timeout = '10s';
ALTER ROLE clone_runner SET lock_timeout = '1s';
ALTER ROLE clone_runner SET transaction_timeout = '15s';
ALTER ROLE clone_runner SET idle_in_transaction_session_timeout = '15s';
ALTER ROLE clone_runner SET temp_file_limit = '256MB';
ALTER ROLE clone_runner SET row_security = on;
ALTER ROLE clone_runner SET jit = off;
GRANT pg_read_all_data TO clone_runner;
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
  --set=template_restored="$template_restored" <<'SQL'
-- appdb bir veri kaynagi degil, onceden restore edilmis salt clone template'idir.
-- Runtime evaluator job database'lerini bu template'ten fiziksel olarak kopyalar.
REVOKE CONNECT, TEMPORARY ON DATABASE :"clone_database" FROM PUBLIC;
REVOKE CONNECT ON DATABASE :"clone_database" FROM clone_runner;
ALTER DATABASE :"clone_database" WITH IS_TEMPLATE true;
ALTER DATABASE :"clone_database" SET advisor.validation_clone = 'on';

CREATE SCHEMA IF NOT EXISTS advisor_clone_meta AUTHORIZATION :"clone_admin";
REVOKE ALL ON SCHEMA advisor_clone_meta FROM PUBLIC;
CREATE TABLE IF NOT EXISTS advisor_clone_meta.template_manifest (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    initialized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    postgres_version text NOT NULL DEFAULT current_setting('server_version'),
    archive_restored boolean NOT NULL DEFAULT false,
    source_ddl_executed boolean NOT NULL DEFAULT false CHECK (NOT source_ddl_executed)
);
INSERT INTO advisor_clone_meta.template_manifest(singleton, archive_restored)
VALUES (true, :'template_restored'::boolean)
ON CONFLICT (singleton) DO UPDATE
SET initialized_at = EXCLUDED.initialized_at,
    postgres_version = EXCLUDED.postgres_version,
    archive_restored = EXCLUDED.archive_restored,
    source_ddl_executed = false;
SQL
