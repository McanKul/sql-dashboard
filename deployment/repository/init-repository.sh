#!/usr/bin/env bash
set -Eeuo pipefail

: "${POWA_COLLECTOR_PASSWORD:?POWA_COLLECTOR_PASSWORD tanimli olmali}"
: "${ADVISOR_API_PASSWORD:?ADVISOR_API_PASSWORD tanimli olmali}"
: "${REGISTER_DEMO_SOURCE:=true}"

psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  --set=collector_password="$POWA_COLLECTOR_PASSWORD" \
  --set=api_password="$ADVISOR_API_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS "PoWA";
CREATE EXTENSION IF NOT EXISTS powa WITH SCHEMA "PoWA";
-- Normal fresh installs already populate powa_roles.  A dump/restore can leave
-- those mappings empty, in which case reuse the restored cluster roles and
-- rebuild the ACLs without trying to recreate them.
SELECT "PoWA".setup_powa_roles(true)
WHERE NOT EXISTS (
    SELECT 1 FROM "PoWA".powa_roles WHERE rolname IS NOT NULL
);

CREATE ROLE powa_collector LOGIN PASSWORD :'collector_password';
CREATE ROLE advisor_api LOGIN PASSWORD :'api_password';

GRANT CONNECT ON DATABASE powa_repository TO powa_collector, advisor_api;
GRANT USAGE ON SCHEMA "PoWA" TO powa_collector, advisor_api;
GRANT powa_read_all_data TO advisor_api;
GRANT powa_read_all_data, powa_write_all_data, powa_snapshot TO powa_collector;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA "PoWA" TO powa_collector;
SQL

case "$REGISTER_DEMO_SOURCE" in
  true|TRUE|1|yes|YES)
    psql --set=ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
SELECT "PoWA".powa_register_server(
    hostname => 'source-db',
    port => 5432,
    alias => 'test-source',
    username => 'powa_collector',
    password => NULL,
    dbname => 'powa',
    frequency => 5,
    powa_coalesce => 100,
    retention => interval '90 days',
    allow_ui_connection => false,
    extensions => ARRAY['pg_qualstats', 'pg_stat_kcache']::text[]
);
SQL
    ;;
  false|FALSE|0|no|NO)
    echo "Demo source registration disabled (REGISTER_DEMO_SOURCE=${REGISTER_DEMO_SOURCE})."
    ;;
  *)
    echo "REGISTER_DEMO_SOURCE true/false olmali: ${REGISTER_DEMO_SOURCE}" >&2
    exit 1
    ;;
esac
