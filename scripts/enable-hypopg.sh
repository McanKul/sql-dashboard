#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"

available_version="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT default_version FROM pg_available_extensions WHERE name='hypopg'")"
[[ "$available_version" == "1.4.3" ]] \
  || fail "Image icinde HypoPG 1.4.3 bulunamadi: ${available_version:-yok}"

docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 -U postgres -d appdb <<'SQL'
\getenv evaluator_password ADVISOR_EVALUATOR_PASSWORD

SELECT format(
    'CREATE ROLE advisor_evaluator LOGIN PASSWORD %L NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2',
    :'evaluator_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='advisor_evaluator')
\gexec

SELECT format('ALTER ROLE advisor_evaluator LOGIN PASSWORD %L', :'evaluator_password')
\gexec
ALTER ROLE advisor_evaluator NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2;
ALTER ROLE advisor_evaluator SET default_transaction_read_only = on;
ALTER ROLE advisor_evaluator SET statement_timeout = '2s';
ALTER ROLE advisor_evaluator SET lock_timeout = '250ms';
ALTER ROLE advisor_evaluator SET idle_in_transaction_session_timeout = '3s';

CREATE SCHEMA IF NOT EXISTS advisor_hypopg;
CREATE EXTENSION IF NOT EXISTS hypopg WITH SCHEMA advisor_hypopg;
REVOKE ALL ON SCHEMA advisor_hypopg FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA advisor_hypopg FROM PUBLIC;
GRANT USAGE ON SCHEMA advisor_hypopg TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_reset() TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_create_index(text) TO advisor_evaluator;
GRANT EXECUTE ON FUNCTION advisor_hypopg.hypopg_relation_size(oid) TO advisor_evaluator;

GRANT CONNECT ON DATABASE appdb TO advisor_evaluator;
GRANT USAGE ON SCHEMA public TO advisor_evaluator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO advisor_evaluator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO advisor_evaluator;
SQL

capability="$(docker compose exec -T source-db psql -U postgres -d appdb -AtF '|' -qc \
  "SELECT
      (SELECT extversion FROM pg_extension WHERE extname='hypopg'),
      (SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole
              AND NOT rolreplication AND NOT rolbypassrls AND rolconnlimit = 2
         FROM pg_roles WHERE rolname='advisor_evaluator'),
      has_function_privilege('advisor_evaluator', 'advisor_hypopg.hypopg_create_index(text)', 'EXECUTE'),
      has_table_privilege('advisor_evaluator', 'public.orders', 'SELECT')")"
[[ "$capability" == "1.4.3|t|t|t" ]] \
  || fail "HypoPG/evaluator capability dogrulanamadi: ${capability:-bos}"

pass "HypoPG 1.4.3 ve salt-okunur advisor_evaluator rolu hazir"
