#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

holder_pid=""
cleanup_holder() {
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
}
trap cleanup_holder EXIT INT TERM

docker compose config --quiet
docker compose ps --services --status running | grep -qx source-db \
  || fail "source-db calismiyor"
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"

source_image_id="$(docker compose images -q source-db)"
[[ -n "$source_image_id" ]] || fail "source-db image kimligi bulunamadi"
image_version="$(docker image inspect "$source_image_id" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
[[ "$image_version" == *"pg_wait_sampling-1.1.11"* ]] \
  || fail "Image release 1.1.11 olarak etiketli degil: ${image_version:-etiket-yok}. source-db image'ini yeniden build edin."

available_version="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT default_version FROM pg_available_extensions WHERE name='pg_wait_sampling'")"
[[ "$available_version" == "1.1" ]] \
  || fail "Image icinde pg_wait_sampling SQL extension 1.1 yok: ${available_version:-yok}"

preload="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  'SHOW shared_preload_libraries')"
[[ ",${preload// /}," == *",pg_wait_sampling,"* ]] \
  || fail "pg_wait_sampling preload edilmemis. source-db container'ini yeni compose command'i ile yeniden olusturun."

docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_wait_sampling;
SELECT "PoWA".powa_activate_extension(0, 'pg_wait_sampling');
SQL

source_check="$(docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --dbname powa --tuples-only --no-align --field-separator='|' \
  --command "SELECT
      (SELECT extversion FROM pg_extension WHERE extname='pg_wait_sampling'),
      current_setting('pg_wait_sampling.profile_period'),
      current_setting('pg_wait_sampling.profile_pid'),
      current_setting('pg_wait_sampling.profile_queries'),
      current_setting('pg_wait_sampling.sample_cpu'),
      (SELECT count(*) >= 0 FROM \"PoWA\".powa_wait_sampling_src(0))")"
[[ "$source_check" == "1.1|10|off|top|off|t" ]] \
  || fail "Kaynak wait sampling ayar/datasource kontrolu basarisiz: ${source_check:-bos}"
pass "Kaynak pg_wait_sampling release 1.1.11 / extension 1.1 ve top-level profil ayarlari hazir"

demo_server_id="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT id FROM \"PoWA\".powa_servers WHERE alias='test-source'")"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] \
  || fail "Repository'de test-source kaydi bulunamadi"

activation_ok="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "SELECT \"PoWA\".powa_activate_extension(${demo_server_id}, 'pg_wait_sampling')")"
[[ "$activation_ok" == t ]] \
  || fail "Repository pg_wait_sampling datasource aktivasyonu basarisiz"

wait_retention_ok="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -Atqc \
  "UPDATE \"PoWA\".powa_extension_config
      SET retention = interval '30 days'
    WHERE extname = 'pg_wait_sampling'
      AND retention IS DISTINCT FROM interval '30 days';
   SELECT bool_and(retention = interval '30 days')
     FROM \"PoWA\".powa_extension_config
    WHERE extname = 'pg_wait_sampling';")"
[[ "$wait_retention_ok" == t ]] \
  || fail "Repository pg_wait_sampling retention 30 gun olarak ayarlanamadi"

# Existing named volumes do not rerun docker-entrypoint init scripts. Apply the
# rerunnable adapter without deleting repository history.
docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --file /docker-entrypoint-initdb.d/15-powa-qualstats-purge-compat.sql >/dev/null
docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --file /docker-entrypoint-initdb.d/20-advisor-schema.sql >/dev/null
pass "Repository datasource, 30 gun wait retention ve advisor wait adapter'i guncel"

docker compose up -d --force-recreate --no-deps collector >/dev/null

snapshot_epoch() {
  docker compose exec -T repository-db psql -U postgres -p 5433 \
    -d powa_repository -Atqc \
    "SELECT CASE
       WHEN snapts = '-infinity'::timestamptz THEN 0
       ELSE extract(epoch FROM snapts)
     END
       FROM \"PoWA\".powa_snapshot_metas
      WHERE srvid=${demo_server_id}"
}

forced_snapshot_epoch=""
force_snapshot() {
  local previous_epoch="$1"
  local state=""
  local advanced=""
  local errors=""
  local current_epoch=""
  local attempt
  [[ "$previous_epoch" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "Onceki snapshot zamani gecersiz: ${previous_epoch:-bos}"

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
              cardinality(coalesce(errors, ARRAY[]::text[])),
              CASE WHEN snapts = '-infinity'::timestamptz
                   THEN 0 ELSE extract(epoch FROM snapts) END
         FROM \"PoWA\".powa_snapshot_metas
        WHERE srvid=${demo_server_id}")"
    IFS='|' read -r advanced errors current_epoch <<< "$state"
    if [[ "$advanced" == t && "$errors" == 0 \
       && "$current_epoch" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      forced_snapshot_epoch="$current_epoch"
      return 0
    fi
  done
  fail "Collector snapshot ilerlemedi veya hata verdi: ${state:-bos}"
}

lock_key=742042401
generate_advisory_wait() {
  local hold_seconds="$1"
  local held=""
  local attempt
  [[ "$hold_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "Lock bekleme suresi gecersiz: ${hold_seconds}"

  docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
    -U postgres -d appdb -qc \
    "BEGIN;
     SELECT pg_advisory_xact_lock(${lock_key});
     SELECT pg_sleep(${hold_seconds});
     COMMIT;" >/dev/null &
  holder_pid=$!

  for ((attempt = 1; attempt <= 20; attempt++)); do
    held="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
      "SELECT EXISTS (
         SELECT 1 FROM pg_locks
          WHERE locktype='advisory'
            AND classid=0
            AND objid=${lock_key}
            AND objsubid=1
            AND granted
       )")"
    [[ "$held" == t ]] && break
    sleep 0.1
  done
  [[ "$held" == t ]] || fail "Advisory lock holder hazir olmadi"

  docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
    -U postgres -d appdb -qc \
    "SELECT pg_advisory_xact_lock(${lock_key})" >/dev/null
  wait "$holder_pid" || fail "Advisory lock holder oturumu basarisiz"
  holder_pid=""
}

# First create the event series and snapshot its baseline; then add another
# measured wait so the cumulative counter has a real positive delta.
generate_advisory_wait 1.5
previous_epoch="$(snapshot_epoch)"
force_snapshot "$previous_epoch"

generate_advisory_wait 2.5
force_snapshot "$forced_snapshot_epoch"

pipeline_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 \
  -d powa_repository -AtF '|' -qc \
  "SELECT
     coalesce((SELECT enabled FROM \"PoWA\".powa_extension_config
                WHERE srvid=${demo_server_id} AND extname='pg_wait_sampling'), false),
     coalesce((SELECT version FROM \"PoWA\".powa_extension_config
                WHERE srvid=${demo_server_id} AND extname='pg_wait_sampling'), ''),
     (SELECT count(*) = 4 FROM \"PoWA\".powa_functions
       WHERE srvid=${demo_server_id} AND name='pg_wait_sampling' AND enabled
         AND operation IN ('snapshot','aggregate','purge','reset')),
     (SELECT count(*) FROM \"PoWA\".powa_wait_sampling_history_current
       WHERE srvid=${demo_server_id})
       + (SELECT count(*) FROM \"PoWA\".powa_wait_sampling_history
           WHERE srvid=${demo_server_id}),
     coalesce((SELECT sum(samples) FROM advisor.wait_deltas(now() - interval '1 hour')
                WHERE server_id=${demo_server_id}
                  AND event_type='Lock' AND lower(event)='advisory'), 0),
     coalesce((SELECT cardinality(coalesce(errors, ARRAY[]::text[]))
                 FROM \"PoWA\".powa_snapshot_metas
                WHERE srvid=${demo_server_id}), -1),
     coalesce((SELECT retention = interval '30 days'
                 FROM \"PoWA\".powa_extension_config
                WHERE srvid=${demo_server_id}
                  AND extname='pg_wait_sampling'), false)")"

IFS='|' read -r waits_enabled waits_version waits_functions history_rows lock_samples error_count retention_ok <<< "$pipeline_state"
[[ "$waits_enabled" == t && "$waits_version" == "1.1" \
   && "$waits_functions" == t && "$history_rows" =~ ^[0-9]+$ \
   && "$lock_samples" =~ ^[0-9]+$ && "$error_count" == 0 \
   && "$retention_ok" == t ]] \
  || fail "pg_wait_sampling repository durumu gecersiz: ${pipeline_state:-bos}"
((history_rows > 0 && lock_samples > 0)) \
  || fail "Advisory lock wait history/deltasi olusmadi: ${pipeline_state}"

pass "PoWA wait history ve reset-safe advisory Lock deltasi dogrulandi (${lock_samples} sample)"
printf '\npg_wait_sampling 2.4 gecisi tamamlandi; demo verisi silinmedi.\n'
