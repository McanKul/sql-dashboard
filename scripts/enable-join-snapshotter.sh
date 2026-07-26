#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"

join_source_alias="$(docker compose exec -T repository-db printenv JOIN_SOURCE_ALIAS 2>/dev/null || true)"
join_source_alias="${join_source_alias:-test-source}"
[[ "$join_source_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$ ]] \
  || fail "JOIN source alias guvenli degil: ${join_source_alias}"

docker compose exec -T source-db test -r /opt/advisor/sql/003_join_snapshot_source.sql \
  || fail "Source container JOIN outbox SQL dosyasini tasimiyor; source-db'yi yeni compose ile yeniden olusturun"

# Existing named volumes do not rerun docker-entrypoint init scripts.  Create or
# rotate the dedicated source login, then install the atomic capture/reset
# wrapper without deleting pg_qualstats or any existing outbox batch.
docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa <<'SQL'
\getenv join_reader_password ADVISOR_JOIN_SOURCE_PASSWORD

SELECT format(
    'CREATE ROLE advisor_join_reader LOGIN PASSWORD %L NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2',
    :'join_reader_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_join_reader')
\gexec

ALTER ROLE advisor_join_reader LOGIN PASSWORD :'join_reader_password'
  NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 2;
GRANT CONNECT ON DATABASE powa TO advisor_join_reader;
\set collector_user powa_collector
\set join_reader_user advisor_join_reader
\ir /opt/advisor/sql/003_join_snapshot_source.sql
SQL
pass "Source JOIN outbox, atomik capture/reset wrapper'i ve ayri reader rolu hazir"

# Create/rotate the repository-side function-only login before applying the
# rerunnable schema.  The schema itself conditionally handles installations in
# which this role has not been introduced yet.
docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository <<'SQL'
\getenv join_ingest_password ADVISOR_JOIN_REPOSITORY_PASSWORD

SELECT format(
    'CREATE ROLE advisor_join_ingest LOGIN PASSWORD %L NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2',
    :'join_ingest_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'advisor_join_ingest')
\gexec

ALTER ROLE advisor_join_ingest LOGIN PASSWORD :'join_ingest_password'
  NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 2;
GRANT CONNECT ON DATABASE powa_repository TO advisor_join_ingest;
SQL

# All repository-side compatibility, advisor and replay-fixture DDL is owned
# by the checksum-verified migration runner.
bash scripts/migrate-repository.sh >/dev/null

docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository <<'SQL'
\getenv join_source_alias JOIN_SOURCE_ALIAS

SELECT advisor_ingest.bind_join_source_role(
    'advisor_join_ingest',
    :'join_source_alias'
);

UPDATE "PoWA".powa_extension_functions
   SET query_cleanup = 'SELECT advisor_join.capture_and_reset()'
 WHERE extname = 'pg_qualstats'
   AND operation = 'snapshot';
SQL
pass "Repository JOIN ingest, persisted composite aday semasi ve PoWA cleanup hook'u hazir"

source_acl="$(docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa --tuples-only --no-align --field-separator='|' \
  --command "SELECT
      has_function_privilege('powa_collector', 'advisor_join.capture_and_reset()', 'EXECUTE'),
      has_function_privilege('advisor_join_reader', 'advisor_join.fetch_batches(integer)', 'EXECUTE'),
      has_function_privilege('advisor_join_reader', 'advisor_join.list_batch_headers(integer)', 'EXECUTE'),
      has_function_privilege('advisor_join_reader', 'advisor_join.fetch_batch_chunk(bigint,integer)', 'EXECUTE'),
      has_function_privilege('advisor_join_reader', 'advisor_join.ack_batch(bigint)', 'EXECUTE'),
      NOT has_function_privilege('powa_collector', 'advisor_join.assert_outbox_within_limits()', 'EXECUTE'),
      NOT has_function_privilege('advisor_join_reader', 'advisor_join.assert_outbox_within_limits()', 'EXECUTE'),
      NOT has_table_privilege('advisor_join_reader', 'advisor_join.outbox_batches', 'SELECT'),
      NOT COALESCE((
        SELECT has_function_privilege(
                 'powa_collector',
                 format('%I.pg_qualstats_reset()', namespace.nspname),
                 'EXECUTE'
               )
          FROM pg_extension extension
          JOIN pg_namespace namespace ON namespace.oid = extension.extnamespace
         WHERE extension.extname = 'pg_qualstats'
      ), false)")"
[[ "$source_acl" == "t|t|t|t|t|t|t|t|t" ]] \
  || fail "Source least-privilege kontrolu basarisiz: ${source_acl:-bos}"

repository_acl="$(docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --tuples-only --no-align --field-separator='|' \
  --command "SELECT
      has_function_privilege('advisor_join_ingest', 'advisor_ingest.ingest_join_batch(text,bigint,timestamptz,jsonb)', 'EXECUTE'),
      has_function_privilege('advisor_join_ingest', 'advisor_ingest.ingest_join_chunk(text,bigint,timestamptz,integer,integer,integer,boolean,jsonb)', 'EXECUTE'),
      has_function_privilege('advisor_join_ingest', 'advisor_ingest.finalize_join_batch(text,bigint)', 'EXECUTE'),
      has_function_privilege('advisor_join_ingest', 'advisor_ingest.record_join_error(text,text)', 'EXECUTE'),
      has_function_privilege('advisor_join_ingest', 'advisor_ingest.purge_join_source_history(text,interval)', 'EXECUTE'),
      NOT has_function_privilege('advisor_join_ingest', 'advisor_ingest.purge_join_history(interval)', 'EXECUTE'),
      NOT has_function_privilege('advisor_join_ingest', 'advisor_ingest.refresh_candidates(integer,bigint)', 'EXECUTE'),
      NOT has_table_privilege('advisor_join_ingest', 'advisor_ingest.join_snapshot_batches', 'SELECT'),
      NOT has_table_privilege('advisor_join_ingest', 'advisor_ingest.join_batch_staging', 'SELECT'),
      NOT has_table_privilege('advisor_join_ingest', 'advisor_ingest.join_chunk_receipts', 'SELECT'),
      NOT has_table_privilege('advisor_join_ingest', 'advisor_ingest.join_predicate_staging', 'SELECT'),
      NOT has_schema_privilege('advisor_api', 'advisor_ingest', 'USAGE'),
      has_function_privilege('advisor_api', 'advisor.runtime_replay_fixture_status(uuid[],integer,oid,bigint,text)', 'EXECUTE'),
      has_function_privilege('advisor_api', 'advisor.runtime_replay_fixture(uuid,integer,oid,bigint,text)', 'EXECUTE'),
      NOT has_table_privilege('advisor_api', 'advisor_ingest.runtime_replay_fixtures', 'SELECT'),
      EXISTS (
        SELECT 1
         FROM advisor_ingest.join_source_role_bindings AS binding
          JOIN \"PoWA\".powa_servers AS server ON server.id = binding.server_id
         WHERE binding.role_name = 'advisor_join_ingest'
           AND server.alias = '${join_source_alias}'
      )")"
[[ "$repository_acl" == "t|t|t|t|t|t|t|t|t|t|t|t|t|t|t|t" ]] \
  || fail "Repository least-privilege kontrolu basarisiz: ${repository_acl:-bos}"
pass "JOIN ingest rolu tek kaynaga bagli ve yalniz source-scoped wrapper fonksiyonlarini cagirabiliyor"

demo_server_id="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT id FROM \"PoWA\".powa_servers WHERE alias='${join_source_alias}'")"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] \
  || fail "Repository'de ${join_source_alias} kaydi bulunamadi"

docker compose up -d --force-recreate --no-deps join-snapshotter >/dev/null

collector_stopped=false
restore_collector() {
  if [[ "$collector_stopped" == true ]]; then
    docker compose up -d --no-deps collector >/dev/null 2>&1 || true
  fi
}
trap restore_collector EXIT INT TERM

snapshot_epoch() {
  docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -Atqc \
    "SELECT CASE WHEN snapts = '-infinity'::timestamptz THEN 0
                 ELSE extract(epoch FROM snapts) END
       FROM \"PoWA\".powa_snapshot_metas
      WHERE srvid=${demo_server_id}"
}

force_snapshot_after() {
  local previous_epoch="$1"
  local state=""
  local attempt
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if ((attempt == 1 || attempt % 5 == 0)); then
      docker compose exec -T repository-db psql -U postgres -p 5433 \
        -d powa_repository -qc \
        "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
    fi
    sleep 1
    state="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
      -d powa_repository -AtF '|' -qc \
      "SELECT snapts > to_timestamp(${previous_epoch}),
              cardinality(coalesce(errors, ARRAY[]::text[]))
         FROM \"PoWA\".powa_snapshot_metas
        WHERE srvid=${demo_server_id}")"
    [[ "$state" == "t|0" ]] && return 0
  done
  fail "JOIN kabul snapshot'i ilerlemedi: ${state:-bos}"
}

nonempty_batch_count() {
  docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -Atqc \
    "SELECT count(*) FROM advisor_ingest.join_snapshot_batches
      WHERE server_id=${demo_server_id} AND row_count > 0"
}

run_join_workload() {
  docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
    --username postgres --dbname appdb >/dev/null <<'SQL'
SET pg_qualstats.sample_rate = 1;
SELECT 'SELECT count(*) FROM public.customers AS c JOIN public.orders AS o ON o.customer_id = c.id WHERE o.status = ''paid'''
  FROM generate_series(1, 10)
\gexec
SQL
}

capture_round() {
  local previous_epoch
  local previous_batches
  local current_batches=""
  local attempt

  docker compose stop collector >/dev/null
  collector_stopped=true
  previous_epoch="$(snapshot_epoch)"
  previous_batches="$(nonempty_batch_count)"
  run_join_workload
  docker compose up -d --force-recreate --no-deps collector >/dev/null
  collector_stopped=false
  force_snapshot_after "$previous_epoch"

  for ((attempt = 1; attempt <= 30; attempt++)); do
    current_batches="$(nonempty_batch_count)"
    if [[ "$current_batches" =~ ^[0-9]+$ ]] && ((current_batches > previous_batches)); then
      return 0
    fi
    sleep 1
  done
  fail "JOIN snapshotter non-empty batch'i repository'ye tasimadi"
}

# Two reset boundaries are required before a public composite candidate can be
# emitted.  Collector is paused while each deterministic query burst runs so a
# background snapshot cannot consume one burst before its acceptance boundary.
capture_round
capture_round

candidate_state=""
for attempt in $(seq 1 30); do
  candidate_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -AtF '|' -qc \
    "SELECT
       (SELECT status FROM advisor_ingest.join_source_status WHERE server_id=${demo_server_id}),
       (SELECT count(*) FROM advisor.join_predicate_metrics(
          interval '1 hour', ${demo_server_id}, NULL, NULL)),
       (SELECT count(*) FROM advisor.composite_index_candidates(
          interval '1 hour', ${demo_server_id}, NULL, NULL))")"
  IFS='|' read -r join_status join_rows candidate_rows <<< "$candidate_state"
  if [[ "$join_status" == "HEALTHY" && "$join_rows" =~ ^[0-9]+$ \
     && "$candidate_rows" =~ ^[0-9]+$ ]] \
     && ((join_rows > 0 && candidate_rows > 0)); then
    break
  fi
  sleep 1
done

if [[ "$join_status" != "HEALTHY" || ! "$join_rows" =~ ^[0-9]+$ \
   || ! "$candidate_rows" =~ ^[0-9]+$ ]] \
   || ((join_rows <= 0 || candidate_rows <= 0)); then
  fail "JOIN/composite kabul kaniti olusmadi: ${candidate_state:-bos}"
fi

trap - EXIT INT TERM
pass "Iki JOIN snapshot'i, repository aktarimi ve persisted composite aday dogrulandi (${join_rows} JOIN, ${candidate_rows} aday)"
