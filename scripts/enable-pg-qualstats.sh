#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"

# Named volume kullanan mevcut kurulumlarda docker-entrypoint init dosyalari
# tekrar calismaz. Bu migration kaynak extension/grant ve mevcut demo PoWA
# datasource aktivasyonunu kayip veri veya volume silmeden uygular.
docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_qualstats;
SELECT "PoWA".powa_activate_extension(0, 'pg_qualstats');

SELECT format(
    'GRANT EXECUTE ON FUNCTION %I.pg_qualstats(), %I.pg_qualstats_reset() TO powa_collector',
    n.nspname,
    n.nspname
)
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_qualstats'
\gexec
SQL

source_check="$(docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa --tuples-only --no-align --field-separator='|' \
  --command "SELECT
      (SELECT extversion FROM pg_extension WHERE extname = 'pg_qualstats'),
      'pg_qualstats' = ANY(string_to_array(replace(current_setting('shared_preload_libraries'), ' ', ''), ',')),
      (SELECT count(*) >= 0 FROM \"PoWA\".powa_qualstats_src(0)),
      has_function_privilege(
        'powa_collector', format('%I.pg_qualstats_reset()', n.nspname), 'EXECUTE')
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_qualstats'")"
[[ "$source_check" == "2.1.4|t|t|t" ]] \
  || fail "Kaynak pg_qualstats preload/call/grant kontrolu basarisiz: ${source_check:-bos}. Container'i yeni image ve compose ayarlariyla yeniden olusturun."
pass "Kaynak pg_qualstats 2.1.4 preload, datasource ve collector reset yetkisi hazir"

demo_server_id="$(
  printf '%s\n' \
    'SELECT id FROM "PoWA".powa_servers WHERE alias = '\''test-source'\'';' \
  | docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
      --username postgres --port 5433 --dbname powa_repository \
      --tuples-only --no-align
)"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] \
  || fail "Repository'de test-source kaydi bulunamadi"

activation_ok="$(
  printf '%s\n' \
    "SELECT \"PoWA\".powa_activate_extension(${demo_server_id}, 'pg_qualstats');" \
  | docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
      --username postgres --port 5433 --dbname powa_repository \
      --tuples-only --no-align
)"
[[ "$activation_ok" == t ]] \
  || fail "Repository pg_qualstats datasource aktivasyonu basarisiz"
pass "Repository test-source pg_qualstats datasource etkin"

# The migration runner owns the PoWA compatibility repair and records its
# checksum on both fresh and existing named volumes.
bash scripts/migrate-repository.sh >/dev/null
pass "PoWA 5.2.0 pg_qualstats retention purge uyumlulugu hazir"

previous_state="$({
  printf '%s\n' "SELECT
    CASE WHEN isfinite(m.snapts) THEN extract(epoch FROM m.snapts) ELSE 0 END,
    greatest(
      coalesce((SELECT max(extract(epoch FROM ts)) FROM \"PoWA\".powa_qualstats_quals_history_current WHERE srvid=${demo_server_id}), 0),
      coalesce((SELECT max(extract(epoch FROM upper(coalesce_range))) FROM \"PoWA\".powa_qualstats_quals_history WHERE srvid=${demo_server_id}), 0)
    )
  FROM \"PoWA\".powa_snapshot_metas m WHERE m.srvid=${demo_server_id};"
} | docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
      --username postgres --port 5433 --dbname powa_repository \
      --tuples-only --no-align --field-separator='|')"
IFS='|' read -r previous_snap previous_qual_epoch <<< "$previous_state"
previous_snap="${previous_snap:-0}"
previous_qual_epoch="${previous_qual_epoch:-0}"

collector_stopped=false
restore_collector() {
  if [[ "$collector_stopped" == true ]]; then
    docker compose up -d --no-deps collector >/dev/null 2>&1 || true
  fi
}
trap restore_collector EXIT
docker compose stop collector >/dev/null
collector_stopped=true

# Demo migration'inda history ilerlemesini deterministik kanitlayacak kucuk ve
# kendi verisini temizleyen test yuku uretilir.
docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname appdb --command \
  "SET pg_qualstats.sample_rate = 1; SELECT run_advisor_test_workload(5);" >/dev/null

docker compose up -d --force-recreate --no-deps collector >/dev/null
collector_stopped=false

migration_state=""
for attempt in $(seq 1 20); do
  printf '%s\n' "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}';" \
    | docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
        --username postgres --port 5433 --dbname powa_repository >/dev/null
  sleep 2
  migration_state="$({
    printf '%s\n' "SELECT
      extract(epoch FROM m.snapts) > ${previous_snap},
      greatest(
        coalesce((SELECT max(extract(epoch FROM ts)) FROM \"PoWA\".powa_qualstats_quals_history_current WHERE srvid=${demo_server_id}), 0),
        coalesce((SELECT max(extract(epoch FROM upper(coalesce_range))) FROM \"PoWA\".powa_qualstats_quals_history WHERE srvid=${demo_server_id}), 0)
      ) > ${previous_qual_epoch},
      ec.version,
      ec.enabled,
      cardinality(coalesce(m.errors, ARRAY[]::text[]))
    FROM \"PoWA\".powa_snapshot_metas m
    JOIN \"PoWA\".powa_extension_config ec
      ON ec.srvid=m.srvid AND ec.extname='pg_qualstats'
   WHERE m.srvid=${demo_server_id};"
  } | docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
        --username postgres --port 5433 --dbname powa_repository \
        --tuples-only --no-align --field-separator='|')"
  if [[ "$migration_state" == "t|t|2.1.4|t|0" ]]; then
    break
  fi
done

[[ "$migration_state" == "t|t|2.1.4|t|0" ]] \
  || fail "Collector pg_qualstats snapshot/history dogrulamasi basarisiz: ${migration_state:-bos}"
trap - EXIT
pass "Collector yeniden baslatildi; pg_qualstats snapshot ve repository history ilerledi"
