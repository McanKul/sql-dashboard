#!/usr/bin/env bash
set -Eeuo pipefail

api_url="${API_URL:-http://localhost:8000}"
web_url="${WEB_URL:-http://localhost:5173}"

pass() { echo "[OK] $1"; }
fail() { echo "[HATA] $1" >&2; exit 1; }

if python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
  python_bin=python3
elif python -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
  python_bin=python
else
  fail "Python 3.10+ bulunamadi"
fi

docker compose config --quiet
pass "Compose yapilandirmasi gecerli"

for attempt in $(seq 1 30); do
  if curl -fsS "${api_url}/api/v1/health" >/tmp/advisor-health.json 2>/dev/null; then
    break
  fi
  if (( attempt == 30 )); then
    fail "API 60 saniye icinde hazir olmadi"
  fi
  sleep 2
done

"$python_bin" - /tmp/advisor-health.json <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    health = json.load(handle)
assert health['repository'] == 'healthy', health
assert health['database']['powaVersion'] == '5.2.0', health
assert health['database']['postgresVersion'].startswith('18.'), health
PY
pass "API, PostgreSQL 18 repository ve PoWA 5.2.0 saglikli"

source_port="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW port')"
repo_port="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc 'SHOW port')"
[[ "$source_port" == "5432" ]] || fail "Kaynak portu 5432 degil: ${source_port}"
[[ "$repo_port" == "5433" ]] || fail "Repository portu 5433 degil: ${repo_port}"
pass "Iki PostgreSQL instance 5432 ve 5433 portlarinda"

source_version_num="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW server_version_num')"
repo_version_num="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc 'SHOW server_version_num')"
source_data_directory="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW data_directory')"
repo_data_directory="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc 'SHOW data_directory')"
(( source_version_num >= 180000 && source_version_num < 190000 )) \
  || fail "Kaynak PostgreSQL 18 degil: ${source_version_num}"
(( repo_version_num >= 180000 && repo_version_num < 190000 )) \
  || fail "Repository PostgreSQL 18 degil: ${repo_version_num}"
[[ "$source_data_directory" == "/var/lib/postgresql/18/docker" ]] \
  || fail "Kaynak PG18 data directory hatali: ${source_data_directory}"
[[ "$repo_data_directory" == "/var/lib/postgresql/18/docker" ]] \
  || fail "Repository PG18 data directory hatali: ${repo_data_directory}"
pass "Iki PostgreSQL instance PG18 ve kalici data directory duzeni dogru"

expected_pg_image="postgresql-advisor/powa-postgres:18-5.2.0-qualstats-2.1.4-kcache-2.3.2-hypopg-1.4.3"
source_pg_image="$(docker inspect --format '{{.Config.Image}}' "$(docker compose ps -q source-db)")"
repository_pg_image="$(docker inspect --format '{{.Config.Image}}' "$(docker compose ps -q repository-db)")"
[[ "$source_pg_image" == "$expected_pg_image" ]] \
  || fail "Kaynak image PG18 + HypoPG 1.4.3 degil: ${source_pg_image}"
[[ "$repository_pg_image" == "$expected_pg_image" ]] \
  || fail "Repository image PG18 + HypoPG 1.4.3 degil: ${repository_pg_image}"
source_hypopg_available="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT EXISTS (SELECT 1 FROM pg_available_extension_versions WHERE name = 'hypopg' AND version = '1.4.3')")"
repository_hypopg_available="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT EXISTS (SELECT 1 FROM pg_available_extension_versions WHERE name = 'hypopg' AND version = '1.4.3')")"
[[ "$source_hypopg_available" == "t" ]] \
  || fail "Kaynak image icinde HypoPG 1.4.3 extension artifact'i yok"
[[ "$repository_hypopg_available" == "t" ]] \
  || fail "Repository image icinde HypoPG 1.4.3 extension artifact'i yok"
pass "Kaynak ve repository image'lari PG18 + HypoPG 1.4.3 olarak sabit"

source_ext="$(docker compose exec -T source-db psql -U postgres -d powa -Atqc \
  "SELECT string_agg(extname || '=' || extversion, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('powa','pg_stat_statements','pg_qualstats','pg_stat_kcache','btree_gist')")"
repo_ext="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT string_agg(extname || '=' || extversion, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('powa','pg_stat_statements','btree_gist')")"
[[ "$source_ext" == *"powa=5.2.0"* && "$source_ext" == *"pg_stat_statements="* && "$source_ext" == *"pg_qualstats=2.1.4"* && "$source_ext" == *"pg_stat_kcache=2.3.2"* ]] || fail "Kaynak extension seti eksik: ${source_ext}"
[[ "$repo_ext" == *"powa=5.2.0"* && "$repo_ext" == *"pg_stat_statements="* ]] || fail "Repository extension seti eksik: ${repo_ext}"
pass "Kaynak pg_qualstats 2.1.4, pg_stat_kcache 2.3.2 ve iki PoWA extension seti dogru"

source_hypopg_version="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SELECT extversion FROM pg_extension WHERE extname = 'hypopg'")"
repository_hypopg_installed="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hypopg')")"
[[ "$source_hypopg_version" == "1.4.3" ]] \
  || fail "Kaynak appdb HypoPG 1.4.3 etkin degil: ${source_hypopg_version:-yok}"
[[ "$repository_hypopg_installed" == "f" ]] \
  || fail "HypoPG repository database'e sizmis; extension yalniz degerlendirme kaynaginda olmali"
pass "HypoPG 1.4.3 yalniz kaynak appdb'de etkin"

evaluator_health_file=/tmp/advisor-evaluator-health.json
for attempt in $(seq 1 30); do
  if docker compose exec -T evaluator python -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8010/health', timeout=3).read().decode())" \
    >"$evaluator_health_file" 2>/dev/null; then
    break
  fi
  if (( attempt == 30 )); then
    fail "HypoPG evaluator 60 saniye icinde hazir olmadi"
  fi
  sleep 2
done
"$python_bin" - "$evaluator_health_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    health = json.load(handle)
assert health['status'] == 'healthy', health
assert health['database_name'] == 'appdb', health
assert health['role_name'] == 'advisor_evaluator', health
assert health['hypopg_version'] == '1.4.3', health
assert health['default_read_only'] == 'on', health
assert health['ddlExecuted'] is False, health
PY
if evaluator_port="$(docker compose port evaluator 8010 2>/dev/null)" && [[ -n "$evaluator_port" ]]; then
  fail "Evaluator host portuna acilmis: ${evaluator_port}"
fi
pass "Evaluator saglikli, HypoPG 1.4.3 yetenekli, read-only ve yalniz ic agda"

preload="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW shared_preload_libraries')"
[[ "$preload" == *"pg_stat_statements"* && "$preload" == *"pg_qualstats"* && "$preload" == *"pg_stat_kcache"* ]] \
  || fail "pg_stat_statements/pg_qualstats/pg_stat_kcache preload edilmemis: ${preload}"

kcache_settings="$(docker compose exec -T source-db psql -U postgres -d powa -AtF '|' -qc \
  "SELECT current_setting('pg_stat_kcache.track'),
          current_setting('pg_stat_kcache.track_planning'),
          (SELECT count(*) >= 0 FROM \"PoWA\".powa_kcache_src(0))")"
[[ "$kcache_settings" == "top|off|t" ]] \
  || fail "pg_stat_kcache gozlem ayarlari/datasource beklenmiyor: ${kcache_settings:-bos}"
pass "pg_stat_kcache top-level execution CPU takibi etkin; planning takibi kapali"

qualstats_settings="$(docker compose exec -T source-db psql -U postgres -d powa -AtF '|' -qc \
  "SELECT current_setting('pg_qualstats.track_constants'),
          current_setting('pg_qualstats.track_pg_catalog'),
          current_setting('pg_qualstats.resolve_oids'),
          current_setting('pg_qualstats.max')::integer >= current_setting('pg_stat_statements.max')::integer,
          current_setting('pg_qualstats.sample_rate')::numeric > 0
            AND current_setting('pg_qualstats.sample_rate')::numeric <= 1")"
[[ "$qualstats_settings" == "off|off|off|t|t" ]] \
  || fail "pg_qualstats guvenlik/kapasite/sampling ayarlari beklenmiyor: ${qualstats_settings}"

reset_grant="$(docker compose exec -T source-db psql -U postgres -d powa -Atqc \
  "SELECT has_function_privilege(
      'powa_collector', format('%I.pg_qualstats_reset()', n.nspname), 'EXECUTE')
     FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
    WHERE e.extname='pg_qualstats'")"
[[ "$reset_grant" == t ]] || fail "Collector pg_qualstats_reset EXECUTE yetkisi eksik"
pass "pg_qualstats preload, guvenli GUC'lar, kapasite ve reset yetkisi dogru"

ignored_users="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  "SHOW powa.ignored_users")"
ignored_users_compact="${ignored_users// /}"
[[ ",${ignored_users_compact}," == *",powa_collector,"* \
   && ",${ignored_users_compact}," == *",advisor_evaluator,"* ]] \
  || fail "PoWA ignored_users collector/evaluator rollerini kapsamiyor: ${ignored_users}"
pass "Collector ve evaluator sorgulari PoWA urun telemetrisinden dislaniyor"

demo_server_id="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT id FROM \"PoWA\".powa_servers WHERE alias = 'test-source' AND hostname = 'source-db' AND port = 5432")"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] || fail "test-source demo kaydi bulunamadi"

repository_evaluator_row_count() {
  docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
    "WITH evaluator_roles AS (
       SELECT oid
         FROM \"PoWA\".powa_catalog_roles
        WHERE srvid = ${demo_server_id}
          AND rolname = 'advisor_evaluator'
     )
     SELECT
       (SELECT count(*) FROM \"PoWA\".powa_statements s
         JOIN evaluator_roles r ON r.oid = s.userid
        WHERE s.srvid = ${demo_server_id})
       +
       (SELECT count(*) FROM \"PoWA\".powa_statements_history h
         JOIN evaluator_roles r ON r.oid = h.userid
        WHERE h.srvid = ${demo_server_id})
       +
       (SELECT count(*) FROM \"PoWA\".powa_statements_history_current h
         JOIN evaluator_roles r ON r.oid = h.userid
        WHERE h.srvid = ${demo_server_id})"
}

evaluator_repository_rows="$(repository_evaluator_row_count)"
[[ "$evaluator_repository_rows" =~ ^[0-9]+$ ]] \
  || fail "Evaluator repository sizinti sayaci sayisal degil: ${evaluator_repository_rows}"
(( evaluator_repository_rows == 0 )) \
  || fail "Repository'de advisor_evaluator telemetrisi bulundu: ${evaluator_repository_rows} satir"
pass "Repository baslangic durumunda evaluator sorgu telemetrisi yok"

server_check="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT retention = interval '90 days', password IS NULL FROM \"PoWA\".powa_servers WHERE id = ${demo_server_id}")"
all_passwords_null="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  'SELECT bool_and(password IS NULL) FROM "PoWA".powa_servers WHERE id > 0')"
[[ "$server_check" == "t|t" && "$all_passwords_null" == "t" ]] \
  || fail "Remote server/retention/parola kaydi hatali: demo=${server_check}, all_null=${all_passwords_null}"
pass "Demo kaydi, 90 gun retention ve tum kaynaklarda NULL parola dogru"

qualstats_registration="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT ec.enabled,
          (SELECT count(*) = 4
             FROM \"PoWA\".powa_functions f
            WHERE f.srvid = ec.srvid
              AND f.name = 'pg_qualstats'
              AND f.enabled
              AND f.operation IN ('snapshot','aggregate','purge','reset'))
     FROM \"PoWA\".powa_extension_config ec
    WHERE ec.srvid = ${demo_server_id} AND ec.extname = 'pg_qualstats'")"
[[ "$qualstats_registration" == "t|t" ]] \
  || fail "Repository pg_qualstats datasource kaydi eksik: ${qualstats_registration:-yok}"
pass "Repository pg_qualstats datasource ve dort PoWA islemi etkin"

kcache_registration="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT ec.enabled, ec.version,
          (SELECT count(*) = 4
             FROM \"PoWA\".powa_functions f
            WHERE f.srvid = ec.srvid
              AND f.name = 'pg_stat_kcache'
              AND f.enabled
              AND f.operation IN ('snapshot','aggregate','purge','reset'))
     FROM \"PoWA\".powa_extension_config ec
    WHERE ec.srvid = ${demo_server_id} AND ec.extname = 'pg_stat_kcache'")"
[[ "$kcache_registration" == "t|2.3.2|t" ]] \
  || fail "Repository pg_stat_kcache datasource kaydi eksik: ${kcache_registration:-yok}"
pass "Repository pg_stat_kcache datasource ve dort PoWA islemi etkin"

# Yepyeni repository'de ilk snapshot bir delta degil, kaynak sayaclarinin
# baseline'idir. Kontrollu workload'u bundan sonra calistirarak API metriklerinin
# temiz kurulumda da ilk farktan uretilmesini garanti ederiz.
baseline_state=""
for attempt in $(seq 1 20); do
  docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -qc \
    "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
  sleep 2
  baseline_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
    "SELECT
       isfinite(m.snapts),
       cardinality(coalesce(m.errors, ARRAY[]::text[])),
       EXISTS (
         SELECT 1 FROM \"PoWA\".powa_statements_history_current h
          WHERE h.srvid = m.srvid
       ),
       EXISTS (
         SELECT 1 FROM \"PoWA\".powa_kcache_metrics_current h
          WHERE h.srvid = m.srvid
       )
     FROM \"PoWA\".powa_snapshot_metas m
    WHERE m.srvid = ${demo_server_id}")"
  if [[ "$baseline_state" == "t|0|t|t" ]]; then
    break
  fi
done
[[ "$baseline_state" == "t|0|t|t" ]] \
  || fail "Ilk collector baseline snapshot'i olusmadi: ${baseline_state:-bos}"
pass "Collector baseline snapshot'i hazir"

previous_snap="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT CASE WHEN isfinite(snapts) THEN extract(epoch FROM snapts) ELSE 0 END
     FROM \"PoWA\".powa_snapshot_metas WHERE srvid = ${demo_server_id}")"
previous_snap="${previous_snap:-0}"
previous_qual_epoch="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT greatest(
      coalesce((SELECT max(extract(epoch FROM ts)) FROM \"PoWA\".powa_qualstats_quals_history_current WHERE srvid=${demo_server_id}), 0),
      coalesce((SELECT max(extract(epoch FROM upper(coalesce_range))) FROM \"PoWA\".powa_qualstats_quals_history WHERE srvid=${demo_server_id}), 0)
   )")"
previous_kcache_epoch="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT greatest(
      coalesce((SELECT max(extract(epoch FROM (metrics).ts)) FROM \"PoWA\".powa_kcache_metrics_current WHERE srvid=${demo_server_id}), 0),
      coalesce((SELECT max(extract(epoch FROM upper(coalesce_range))) FROM \"PoWA\".powa_kcache_metrics WHERE srvid=${demo_server_id}), 0)
   )")"

# Collector pg_qualstats'i her snapshot sonrasinda resetler. Kontrollu workload
# ile raw JOIN/WHERE yakalamayi yarissiz test etmek icin collector kisa sure durur.
collector_stopped=false
workload_stopped=false
restore_runtime() {
  if [[ "$collector_stopped" == true ]]; then
    docker compose up -d --no-deps collector >/dev/null 2>&1 || true
  fi
  if [[ "$workload_stopped" == true ]]; then
    docker compose up -d --no-deps workload >/dev/null 2>&1 || true
  fi
}
trap restore_runtime EXIT
if docker compose ps --services --status running | grep -qx workload; then
  docker compose stop workload >/dev/null
  workload_stopped=true
fi
docker compose stop collector >/dev/null
collector_stopped=true
docker compose exec -T source-db psql -U postgres -d powa -qc \
  'SELECT pg_qualstats_reset()' >/dev/null

bash scripts/run-test-workload.sh 20 >/tmp/advisor-workload-result.txt
grep -q '"ok": true' /tmp/advisor-workload-result.txt || fail "Test fonksiyonu basarisiz"
raw_qualstats="$(docker compose exec -T source-db psql -U postgres -d powa -AtF '|' -qc \
  "SELECT count(*) FILTER (WHERE lrelid IS NOT NULL AND rrelid IS NOT NULL),
          count(*) FILTER (WHERE (lrelid IS NULL) != (rrelid IS NULL))
     FROM pg_qualstats()
    WHERE dbid = (SELECT oid FROM pg_database WHERE datname = 'appdb')")"
IFS='|' read -r raw_join_quals raw_single_column_quals <<< "$raw_qualstats"
[[ "$raw_join_quals" =~ ^[0-9]+$ && "$raw_single_column_quals" =~ ^[0-9]+$ ]] \
  || fail "pg_qualstats raw sonucu sayisal degil: ${raw_qualstats}"
(( raw_join_quals > 0 && raw_single_column_quals > 0 )) \
  || fail "pg_qualstats raw JOIN/WHERE predicate yakalamadi: ${raw_qualstats}"
pass "run_advisor_test_workload ve raw pg_qualstats JOIN/WHERE yakalama calisti"

docker compose up -d --no-deps collector >/dev/null
collector_stopped=false

dml_pattern_count="$(docker compose exec -T source-db psql -U postgres -d powa -Atqc \
  "SELECT count(*) FROM pg_stat_statements
    WHERE query ~* '^[[:space:]]*(INSERT INTO|UPDATE|DELETE FROM)[[:space:]]+workload_mutations'")"
mutation_rows="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc \
  'SELECT count(*) FROM workload_mutations')"
[[ "$dml_pattern_count" == "3" && "$mutation_rows" == "0" ]] \
  || fail "Kontrollu DML desenleri hatali: patterns=$dml_pattern_count, rows=$mutation_rows"
pass "INSERT/UPDATE/DELETE desenleri olculuyor ve test tablosu birikmiyor"

# Collector yeniden LISTEN durumuna gecmeden gonderilen tek bir NOTIFY kaybolabilir.
# Bekleme boyunca istegi tekrar gonderip hem genel snapshot'i hem qualstats
# tarihcesinin onceki kanittan ileri gittigini birlikte dogrulariz.
qual_pipeline=""
for attempt in $(seq 1 20); do
  docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -qc \
    "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
  sleep 2
  qual_pipeline="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
    "SELECT
       coalesce((SELECT extract(epoch FROM snapts) > ${previous_snap}
                   FROM \"PoWA\".powa_snapshot_metas
                  WHERE srvid = ${demo_server_id}), false),
       greatest(
         coalesce((SELECT max(extract(epoch FROM ts))
                     FROM \"PoWA\".powa_qualstats_quals_history_current
                    WHERE srvid = ${demo_server_id}), 0),
         coalesce((SELECT max(extract(epoch FROM upper(coalesce_range)))
                     FROM \"PoWA\".powa_qualstats_quals_history
                    WHERE srvid = ${demo_server_id}), 0)
       ) > ${previous_qual_epoch},
       greatest(
         coalesce((SELECT max(extract(epoch FROM (metrics).ts))
                     FROM \"PoWA\".powa_kcache_metrics_current
                    WHERE srvid = ${demo_server_id}), 0),
         coalesce((SELECT max(extract(epoch FROM upper(coalesce_range)))
                     FROM \"PoWA\".powa_kcache_metrics
                    WHERE srvid = ${demo_server_id}), 0)
       ) > ${previous_kcache_epoch},
       coalesce((SELECT version
                   FROM \"PoWA\".powa_extension_config
                  WHERE srvid = ${demo_server_id} AND extname = 'pg_qualstats'), ''),
       coalesce((SELECT enabled
                   FROM \"PoWA\".powa_extension_config
                  WHERE srvid = ${demo_server_id} AND extname = 'pg_qualstats'), false),
       coalesce((SELECT version
                   FROM \"PoWA\".powa_extension_config
                  WHERE srvid = ${demo_server_id} AND extname = 'pg_stat_kcache'), ''),
       coalesce((SELECT enabled
                   FROM \"PoWA\".powa_extension_config
                  WHERE srvid = ${demo_server_id} AND extname = 'pg_stat_kcache'), false),
       coalesce((SELECT cardinality(coalesce(errors, ARRAY[]::text[]))
                   FROM \"PoWA\".powa_snapshot_metas
                  WHERE srvid = ${demo_server_id}), -1)")"
  if [[ "$qual_pipeline" == "t|t|t|2.1.4|t|2.3.2|t|0" ]]; then
    break
  fi
done
[[ "$qual_pipeline" == "t|t|t|2.1.4|t|2.3.2|t|0" ]] \
  || fail "pg_qualstats/pg_stat_kcache snapshot ve tarihce akisi ilerlemedi: ${qual_pipeline:-bos}"

repo_qualstats="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT
     (SELECT count(*) FROM \"PoWA\".powa_qualstats_quals WHERE srvid = ${demo_server_id}),
     (SELECT count(*) FROM \"PoWA\".powa_qualstats_quals_history_current WHERE srvid = ${demo_server_id})
       + (SELECT count(*) FROM \"PoWA\".powa_qualstats_quals_history WHERE srvid = ${demo_server_id}),
     (SELECT count(*) FROM \"PoWA\".powa_qualstats_src_tmp WHERE srvid = ${demo_server_id})")"
IFS='|' read -r repo_qual_rows repo_qual_history repo_qual_tmp <<< "$repo_qualstats"
[[ "$repo_qual_rows" =~ ^[0-9]+$ && "$repo_qual_history" =~ ^[0-9]+$ && "$repo_qual_tmp" =~ ^[0-9]+$ ]] \
  || fail "Repository pg_qualstats sonucu sayisal degil: ${repo_qualstats}"
(( repo_qual_rows > 0 && repo_qual_history > 0 && repo_qual_tmp == 0 )) \
  || fail "Repository pg_qualstats satir/tarihce/staging beklenmiyor: ${repo_qualstats}"

repo_kcache="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT
     (SELECT count(*) FROM \"PoWA\".powa_kcache_metrics_current WHERE srvid = ${demo_server_id})
       + (SELECT count(*) FROM \"PoWA\".powa_kcache_metrics WHERE srvid = ${demo_server_id}),
     (SELECT count(*) FROM \"PoWA\".powa_kcache_src_tmp WHERE srvid = ${demo_server_id})")"
IFS='|' read -r repo_kcache_history repo_kcache_tmp <<< "$repo_kcache"
[[ "$repo_kcache_history" =~ ^[0-9]+$ && "$repo_kcache_tmp" =~ ^[0-9]+$ ]] \
  || fail "Repository pg_stat_kcache sonucu sayisal degil: ${repo_kcache}"
(( repo_kcache_history > 0 && repo_kcache_tmp == 0 )) \
  || fail "Repository pg_stat_kcache tarihce/staging beklenmiyor: ${repo_kcache}"
pass "PoWA repository pg_stat_kcache CPU/filesystem tarihcesi calisti"

mapped_qual_columns="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT string_agg(DISTINCT c.relname || '.' || a.attname, ',' ORDER BY c.relname || '.' || a.attname)
     FROM \"PoWA\".powa_qualstats_quals q
     CROSS JOIN LATERAL unnest(q.quals) AS x(relid, attnum, opno, eval_type)
     JOIN \"PoWA\".powa_catalog_class c
       ON c.srvid = q.srvid AND c.dbid = q.dbid AND c.oid = x.relid
     JOIN \"PoWA\".powa_catalog_attribute a
       ON a.srvid = q.srvid AND a.dbid = q.dbid
      AND a.attrelid = x.relid AND a.attnum = x.attnum
    WHERE q.srvid = ${demo_server_id}")"
[[ "$mapped_qual_columns" == *"orders.created_at"* && "$mapped_qual_columns" == *"orders.status"* ]] \
  || fail "Repository predicate-kolon eslemesi eksik: ${mapped_qual_columns:-bos}"
pass "PoWA repository WHERE/filter predicate tarihcesi ve katalog kolon eslemesi calisti"

# Yeni bir queryid ilk goruldugunde PoWA kaydi baseline kabul edilir. Ayni
# kontrollu desenleri ikinci snapshot araliginda yeniden calistirarak dashboard
# API'sinin kullanacagi pozitif statement delta'larini deterministik uretiriz.
api_baseline_snap="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT extract(epoch FROM snapts) FROM \"PoWA\".powa_snapshot_metas WHERE srvid = ${demo_server_id}")"
bash scripts/run-test-workload.sh 5 >/tmp/advisor-workload-second-result.txt
grep -q '"ok": true' /tmp/advisor-workload-second-result.txt \
  || fail "Ikinci kontrollu test fonksiyonu basarisiz"
api_delta_state=""
for attempt in $(seq 1 20); do
  docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -qc \
    "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
  sleep 2
  api_delta_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
    "SELECT
       extract(epoch FROM m.snapts) > ${api_baseline_snap},
       cardinality(coalesce(m.errors, ARRAY[]::text[])),
       EXISTS (
         SELECT 1
           FROM advisor.query_deltas(now() - interval '1 hour') d
          WHERE d.server_id = ${demo_server_id}
            AND d.calls > 0
            AND EXISTS (
              SELECT 1
                FROM \"PoWA\".powa_databases db
               WHERE db.srvid = d.server_id
                 AND db.oid = d.database_id
                 AND db.datname = 'appdb'
            )
       )
     FROM \"PoWA\".powa_snapshot_metas m
    WHERE m.srvid = ${demo_server_id}")"
  if [[ "$api_delta_state" == "t|0|t" ]]; then
    break
  fi
done
[[ "$api_delta_state" == "t|0|t" ]] \
  || fail "Dashboard icin pozitif statement delta olusmadi: ${api_delta_state:-bos}"
pass "Dashboard API'si icin ikinci olcum deltasi hazir"

if [[ "$workload_stopped" == true ]]; then
  docker compose up -d --no-deps workload >/dev/null
  workload_stopped=false
fi
trap - EXIT

for attempt in $(seq 1 12); do
  snapshots="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
    "SELECT count(DISTINCT (record).ts) FROM \"PoWA\".powa_statements_history_current WHERE srvid = ${demo_server_id}")"
  if (( snapshots >= 2 )); then break; fi
  sleep 2
done
(( snapshots >= 2 )) || fail "Iki snapshot olusmadi (mevcut: ${snapshots})"
pass "Collector en az iki snapshot yazdi"

collector_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT status || '|' || cardinality(errors) FROM advisor.v_collector_health WHERE server_id = ${demo_server_id}")"
[[ "$collector_state" == "HEALTHY|0" ]] || fail "Collector sagligi beklenmiyor: ${collector_state}"
pass "Collector gecikmesi ve hata durumu saglikli"

curl -fsS -H 'X-Advisor-Role: analyst' \
  "${api_url}/api/v1/queries?window=1h&pageSize=10" >/tmp/advisor-queries-authorized.json
curl -fsS "${api_url}/api/v1/queries?window=1h&pageSize=10" >/tmp/advisor-queries-viewer.json

read -r server_id database_id query_id < <("$python_bin" - /tmp/advisor-queries-authorized.json <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert data['total'] > 0, data
item = data['items'][0]
assert item['sqlVisible'] is True
assert item['calls'] > 0
assert 0 <= item['impactScore'] <= 100
cpu = item['cpu']
assert cpu['capability']['available'] is True, item
assert cpu['capability']['dataAvailable'] is True, item
assert cpu['capability']['version'] == '2.3.2', item
assert cpu['totalTimeMs'] >= 0, item
assert cpu['userTimeMs'] >= 0 and cpu['systemTimeMs'] >= 0, item
assert cpu['percentOfExecTime'] >= 0, item
assert cpu['scoreIncluded'] is False, item
print(item['serverId'], item['databaseId'], item['queryId'])
PY
)
query_id="${query_id%$'\r'}"

"$python_bin" - /tmp/advisor-queries-viewer.json <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert data['items'], data
assert all(item['sqlVisible'] is False for item in data['items'])
assert all('analyst yetkisi' in item['sql'] for item in data['items'])
PY
pass "Sorgu API'si gercek CPU dahil metrik donuyor ve yetkisiz SQL maskeleniyor"

calibration_state="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "WITH metrics AS (SELECT * FROM advisor.query_metrics(interval '1 hour'))
   SELECT
     NOT EXISTS (
       SELECT 1 FROM metrics
        WHERE (regression_percent < 20 OR previous_calls < 20 OR calls < 20)
          AND regression_score <> 0
     ),
     NOT EXISTS (
       SELECT 1 FROM metrics m
        WHERE NOT EXISTS (
          SELECT 1 FROM advisor.query_deltas(now() - interval '1 hour') d
           WHERE d.server_id=m.server_id AND d.database_id=m.database_id
             AND d.query_id=m.query_id AND d.toplevel
             AND d.sample_at >= now() - interval '1 hour'
        )
     ),
     count(*) FILTER (WHERE priority='CRITICAL'),
     round(min(impact_score)::numeric, 2),
     round(max(impact_score)::numeric, 2)
   FROM metrics")"
IFS='|' read -r regression_gate top_level_only critical_count min_score max_score <<< "$calibration_state"
[[ "$regression_gate" == t && "$top_level_only" == t ]] \
  || fail "Puan kalibrasyon guard'lari basarisiz: ${calibration_state:-bos}"
pass "Kalibrasyon: top-level toplam, %20/20-cagri regresyon gate'i ve skor araligi dogru (critical=${critical_count}, min=${min_score}, max=${max_score})"

predicate_identity="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT query_id, database_id
     FROM advisor.predicate_metrics(interval '1 hour', ${demo_server_id}, NULL, NULL)
    WHERE schema_name <> 'unknown'
    ORDER BY CASE signal WHEN 'INDEX_CANDIDATE' THEN 1 WHEN 'REVIEW' THEN 2 ELSE 3 END,
             occurrences DESC
    LIMIT 1")"
IFS='|' read -r predicate_query_id predicate_database_id <<< "$predicate_identity"
[[ "$predicate_query_id" =~ ^-?[0-9]+$ && "$predicate_database_id" =~ ^[0-9]+$ ]] \
  || fail "Predicate endpoint kabul sorgusu bulunamadi: ${predicate_identity:-bos}"
curl -fsS \
  "${api_url}/api/v1/queries/${predicate_query_id}/predicates?window=1h&serverId=${demo_server_id}&databaseId=${predicate_database_id}" \
  >/tmp/advisor-predicates.json
"$python_bin" - /tmp/advisor-predicates.json <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
capability = data['capability']
assert capability['available'] is True, data
assert capability['dataAvailable'] is True, data
assert capability['coverage'] == 'WHERE_FILTER_ONLY', data
assert capability['joinsAvailable'] is False, data
assert capability['ddlGenerated'] is False, data
assert data['items'], data
for item in data['items']:
    assert item['occurrences'] > 0, item
    assert item['rowsProcessed'] >= item['rowsFiltered'] >= 0, item
    assert item['filterRatio'] is None or 0 <= item['filterRatio'] <= 1, item
    assert item['sampleCount'] > 0, item
    assert 'CREATE INDEX' not in item['recommendation'].upper(), item
PY
pass "pg_qualstats WHERE/filter kaniti API ve guvenli index adayi gozlemleri calisiyor"

source_evaluation_identity="$(docker compose exec -T source-db psql -U postgres -d appdb -AtF '|' -qc \
  "SELECT (SELECT oid FROM pg_database WHERE datname = current_database()),
          'public.orders'::regclass::oid")"
IFS='|' read -r source_appdb_oid source_orders_oid <<< "$source_evaluation_identity"
[[ "$source_appdb_oid" =~ ^[0-9]+$ && "$source_orders_oid" =~ ^[0-9]+$ ]] \
  || fail "Canli evaluator kaynak kimligi cozumlenemedi: ${source_evaluation_identity:-bos}"

source_index_fingerprint() {
  docker compose exec -T source-db psql -U postgres -d appdb -AtF '|' -qc \
    "SELECT count(*),
            md5(coalesce(string_agg(
              i.indexrelid::text || ':' || pg_get_indexdef(i.indexrelid),
              E'\\n' ORDER BY i.indexrelid
            ), ''))
       FROM pg_index i
       JOIN pg_class relation ON relation.oid = i.indrelid
       JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'"
}

indexes_before_evaluation="$(source_index_fingerprint)"
evaluation_candidates_file=/tmp/advisor-index-evaluation-candidates.tsv
docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT m.query_id, m.database_id, m.qual_id, m.relation_id
     FROM advisor.predicate_metrics(interval '1 hour', ${demo_server_id}, ${source_appdb_oid}::oid, NULL) m
     JOIN \"PoWA\".powa_statements statement
       ON statement.srvid = m.server_id
      AND statement.dbid = m.database_id
      AND statement.queryid = m.query_id
      AND statement.userid = m.user_id
    WHERE m.relation_id = ${source_orders_oid}::oid
      AND m.schema_name = 'public'
      AND m.table_name = 'orders'
      AND cardinality(m.column_names) = 1
      AND cardinality(m.operator_oids) > 0
      AND m.eval_type = 'FILTER'
      AND m.signal IN ('INDEX_CANDIDATE', 'REVIEW')
      AND m.sample_count >= 2
      AND m.occurrences >= 5
      AND m.rows_processed >= 1000
      AND statement.query ~* '^[[:space:]]*SELECT[[:space:]]'
    ORDER BY
      CASE
        WHEN regexp_replace(btrim(statement.query), '[[:space:]]+', ' ', 'g') =
             'SELECT count(*) FROM orders WHERE status = ' || chr(36) || '1'
          THEN 0
        WHEN m.column_names = ARRAY['status']::text[] THEN 1
        ELSE 2
      END,
      m.occurrences DESC,
      m.sample_count DESC
    LIMIT 20" >"$evaluation_candidates_file"

[[ -s "$evaluation_candidates_file" ]] \
  || fail "HypoPG kabul testi icin canli, tek kolonlu ve yeniden oynatilabilir SELECT predicate bulunamadi"

evaluation_validated=false
evaluation_attempts=""
evaluation_result_file=/tmp/advisor-index-evaluation.json
while IFS='|' read -r evaluation_query_id evaluation_database_id evaluation_qual_id evaluation_relation_id; do
  evaluation_relation_id="${evaluation_relation_id%$'\r'}"
  [[ "$evaluation_query_id" =~ ^-?[0-9]+$ \
     && "$evaluation_database_id" =~ ^[0-9]+$ \
     && "$evaluation_qual_id" =~ ^-?[0-9]+$ \
     && "$evaluation_relation_id" =~ ^[0-9]+$ ]] || continue

  evaluation_payload="$(printf \
    '{"serverId":%s,"databaseId":%s,"qualId":"%s","relationId":%s}' \
    "$demo_server_id" "$evaluation_database_id" "$evaluation_qual_id" "$evaluation_relation_id")"
  if ! evaluation_http_code="$(curl -sS -o "$evaluation_result_file" -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -H 'X-Advisor-Role: analyst' \
    "${api_url}/api/v1/queries/${evaluation_query_id}/index-evaluations?window=1h" \
    --data "$evaluation_payload")"; then
    evaluation_attempts+=" ${evaluation_query_id}:HTTP_ERROR"
    continue
  fi

  if [[ "$evaluation_http_code" == "200" ]] && \
     "$python_bin" - "$evaluation_result_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert data['status'] == 'VALIDATED', data
assert data['reasonCode'] == 'COST_REDUCTION_CONFIRMED', data
assert data['ddlExecuted'] is False, data
candidate = data['candidate']
assert candidate['method'] == 'btree', candidate
assert len(candidate['columns']) == 1, candidate
assert candidate['copyable'] is True, candidate
sql = candidate['createIndexSql']
assert sql.startswith('CREATE INDEX CONCURRENTLY '), sql
assert sql.rstrip().endswith(';'), sql
validation = data['validation']
assert validation['mode'] in {'GENERIC_PLAN', 'PLAIN_PLAN'}, validation
assert validation['hypopgVersion'] == '1.4.3', validation
assert validation['baselineTotalCost'] > validation['hypotheticalTotalCost'] >= 0, validation
assert validation['costReductionPercent'] > 0, validation
assert validation['hypotheticalIndexUsed'] is True, validation
assert validation['estimatedIndexSizeBytes'] >= 0, validation
assert validation['tableSizeBytes'] > 0, validation
assert validation['evaluatedAt'], validation
confidence = data['confidence']
assert confidence['level'] in {'MEDIUM', 'HIGH'}, confidence
assert confidence['reasons'], confidence
PY
  then
    evaluation_validated=true
    break
  fi

  evaluation_reason="$($python_bin - "$evaluation_result_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        data = json.load(handle)
    print(data.get('reasonCode') or data.get('detail') or 'INVALID_RESPONSE')
except Exception:
    print('INVALID_JSON')
PY
)"
  evaluation_attempts+=" ${evaluation_query_id}:${evaluation_http_code}/${evaluation_reason}"
done <"$evaluation_candidates_file"

[[ "$evaluation_validated" == true ]] \
  || fail "Canli predicate adaylarindan hicbiri HypoPG ile dogrulanamadi:${evaluation_attempts:- aday yok}"
pass "Analyst POST canli predicate icin kopyalanabilir SQL ve HypoPG plan kaniti donduruyor"

viewer_evaluation_file=/tmp/advisor-index-evaluation-viewer.json
viewer_evaluation_http_code="$(curl -sS -o "$viewer_evaluation_file" -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  "${api_url}/api/v1/queries/${evaluation_query_id}/index-evaluations?window=1h" \
  --data "$evaluation_payload")"
[[ "$viewer_evaluation_http_code" == "403" ]] \
  || fail "Viewer HypoPG endpoint'i 403 yerine ${viewer_evaluation_http_code} dondu"
"$python_bin" - "$viewer_evaluation_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
assert 'analyst yetkisi' in data['detail'], data
PY
pass "Viewer HypoPG plan dogrulamasina erisemiyor"

indexes_after_evaluation="$(source_index_fingerprint)"
[[ "$indexes_after_evaluation" == "$indexes_before_evaluation" ]] \
  || fail "HypoPG degerlendirmesi gercek index katalogunu degistirdi: once=${indexes_before_evaluation}, sonra=${indexes_after_evaluation}"

evaluation_previous_snap="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT extract(epoch FROM snapts) FROM \"PoWA\".powa_snapshot_metas WHERE srvid = ${demo_server_id}")"
evaluation_snapshot_advanced=false
for attempt in $(seq 1 20); do
  docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -qc \
    "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${demo_server_id}'" >/dev/null
  sleep 2
  evaluation_snapshot_advanced="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
    "SELECT extract(epoch FROM snapts) > ${evaluation_previous_snap}
       FROM \"PoWA\".powa_snapshot_metas WHERE srvid = ${demo_server_id}")"
  [[ "$evaluation_snapshot_advanced" == "t" ]] && break
done
[[ "$evaluation_snapshot_advanced" == "t" ]] \
  || fail "Evaluator sonrasi collector snapshot'i ilerlemedi"

evaluator_repository_rows="$(repository_evaluator_row_count)"
[[ "$evaluator_repository_rows" == "0" ]] \
  || fail "advisor_evaluator EXPLAIN telemetrisi repository'ye sizdi: ${evaluator_repository_rows} satir"
pass "HypoPG gercek index/DDL olusturmadi ve evaluator sorgulari repository'ye sizmadi"

http_seconds="$(curl -fsS -o /tmp/advisor-performance.json -w '%{time_total}' \
  -H 'X-Advisor-Role: analyst' "${api_url}/api/v1/queries?window=24h&pageSize=50")"
"$python_bin" - "$http_seconds" <<'PY'
import sys
elapsed = float(sys.argv[1])
assert elapsed < 2.0, f'queries API hedefi asildi: {elapsed:.3f}s'
PY
pass "24 saat sorgu API yaniti 2 saniyenin altinda (${http_seconds}s)"

curl -fsS -X PATCH \
  -H 'Content-Type: application/json' \
  "${api_url}/api/v1/queries/${query_id}/annotation?serverId=${server_id}&databaseId=${database_id}" \
  --data '{"status":"IN_REVIEW","note":"Otomatik kabul testi","updatedBy":"acceptance-test"}' \
  >/tmp/advisor-annotation.json

audit_count="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT count(*) FROM advisor.audit_log WHERE actor = 'acceptance-test' AND action IN ('ANNOTATION_CREATED','ANNOTATION_UPDATED')")"
(( audit_count >= 1 )) || fail "Annotation audit kaydi olusmadi"
pass "Not/durum degisikligi audit loga yazildi"

api_environment="$(docker compose exec -T api env)"
[[ "$api_environment" != *"source-db"* && "$api_environment" != *":5432"* && "$api_environment" != *"/appdb"* ]] \
  || fail "API containerinda kaynak DB baglanti bilgisi bulundu"
[[ "$api_environment" != *"EVALUATOR_DATABASE_URL="* \
   && "$api_environment" != *"ADVISOR_EVALUATOR_PASSWORD="* ]] \
  || fail "API containerina evaluator kaynak DSN/parolasi sizmis"
pass "API yalniz repository ve ic evaluator endpoint bilgisini tasiyor; kaynak DSN/parolasi yok"

if docker compose ps --services --status running | grep -qx web; then
  curl -fsS "${web_url}/healthz" >/dev/null
  pass "Web arayuzu saglikli"
fi

echo
echo "Iterasyon 1, 2.1-B pg_qualstats, 2.2 HypoPG, kalibrasyon ve 2.3 pg_stat_kcache kabul kontrolleri tamamlandi."
