#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"

available_version="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT default_version FROM pg_available_extensions WHERE name='pg_stat_kcache'")"
[[ "$available_version" == "2.3.2" ]] \
  || fail "Image icinde pg_stat_kcache 2.3.2 yok: ${available_version:-yok}. Yeni image'i build edip source-db'yi yeniden olusturun."

preload="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  'SHOW shared_preload_libraries')"
[[ ",${preload// /}," == *",pg_stat_kcache,"* ]] \
  || fail "pg_stat_kcache preload edilmemis. source-db container'ini yeni compose command'i ile yeniden olusturun."

docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_kcache;
SELECT "PoWA".powa_activate_extension(0, 'pg_stat_kcache');
SQL

source_check="$(docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa --tuples-only --no-align --field-separator='|' \
  --command "SELECT
      (SELECT extversion FROM pg_extension WHERE extname='pg_stat_kcache'),
      current_setting('pg_stat_kcache.track'),
      current_setting('pg_stat_kcache.track_planning'),
      (SELECT count(*) >= 0 FROM \"PoWA\".powa_kcache_src(0))")"
[[ "$source_check" == "2.3.2|top|off|t" ]] \
  || fail "Kaynak pg_stat_kcache ayar/datasource kontrolu basarisiz: ${source_check:-bos}"
pass "Kaynak pg_stat_kcache 2.3.2 preload ve PoWA datasource hazir"

demo_server_id="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT id FROM \"PoWA\".powa_servers WHERE alias='test-source'")"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] \
  || fail "Repository'de test-source kaydi bulunamadi"

activation_ok="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT \"PoWA\".powa_activate_extension(${demo_server_id}, 'pg_stat_kcache')")"
[[ "$activation_ok" == t ]] \
  || fail "Repository pg_stat_kcache datasource aktivasyonu basarisiz"

# Existing named volumes do not rerun docker-entrypoint init scripts.  Apply the
# rerunnable advisor adapter so CPU fields become available without data loss.
docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --file /docker-entrypoint-initdb.d/15-powa-qualstats-purge-compat.sql >/dev/null
docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --file /docker-entrypoint-initdb.d/20-advisor-schema.sql >/dev/null
pass "Repository datasource ve advisor CPU adapter'i guncel"

previous_epoch="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT greatest(
      coalesce((SELECT max(extract(epoch FROM (metrics).ts))
                  FROM \"PoWA\".powa_kcache_metrics_current
                 WHERE srvid=${demo_server_id}), 0),
      coalesce((SELECT max(extract(epoch FROM upper(coalesce_range)))
                  FROM \"PoWA\".powa_kcache_metrics
                 WHERE srvid=${demo_server_id}), 0)
   )")"
previous_epoch="${previous_epoch:-0}"

docker compose up -d --force-recreate --no-deps collector >/dev/null
bash scripts/run-test-workload.sh 20 >/dev/null

pipeline_state=""
for attempt in $(seq 1 20); do
  docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -qc \
    "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
  sleep 2
  pipeline_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -AtF '|' -qc \
    "SELECT
       coalesce((SELECT enabled FROM \"PoWA\".powa_extension_config
                  WHERE srvid=${demo_server_id} AND extname='pg_stat_kcache'), false),
       coalesce((SELECT version FROM \"PoWA\".powa_extension_config
                  WHERE srvid=${demo_server_id} AND extname='pg_stat_kcache'), ''),
       greatest(
         coalesce((SELECT max(extract(epoch FROM (metrics).ts))
                     FROM \"PoWA\".powa_kcache_metrics_current
                    WHERE srvid=${demo_server_id}), 0),
         coalesce((SELECT max(extract(epoch FROM upper(coalesce_range)))
                     FROM \"PoWA\".powa_kcache_metrics
                    WHERE srvid=${demo_server_id}), 0)
       ) > ${previous_epoch},
       coalesce((SELECT cardinality(coalesce(errors, ARRAY[]::text[]))
                   FROM \"PoWA\".powa_snapshot_metas
                  WHERE srvid=${demo_server_id}), -1)")"
  [[ "$pipeline_state" == "t|2.3.2|t|0" ]] && break
done

[[ "$pipeline_state" == "t|2.3.2|t|0" ]] \
  || fail "pg_stat_kcache snapshot/history akisi ilerlemedi: ${pipeline_state:-bos}"

cpu_rows="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT count(*) FROM advisor.query_metrics(interval '1 hour')
    WHERE kcache_available AND kcache_data_available
      AND cpu_total_time_ms >= 0")"
(( cpu_rows > 0 )) \
  || fail "Advisor query adapter'i CPU verisi uretmedi"
pass "pg_stat_kcache repository history ve sorgu CPU metrikleri dogrulandi"
