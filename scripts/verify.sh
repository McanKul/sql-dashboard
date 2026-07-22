#!/usr/bin/env bash
set -Eeuo pipefail

api_url="${API_URL:-http://localhost:8000}"
web_url="${WEB_URL:-http://localhost:5173}"

pass() { echo "[OK] $1"; }
fail() { echo "[HATA] $1" >&2; exit 1; }

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

python3 - <<'PY'
import json
with open('/tmp/advisor-health.json', encoding='utf-8') as handle:
    health = json.load(handle)
assert health['repository'] == 'healthy', health
assert health['database']['powaVersion'] == '5.2.0', health
PY
pass "API, repository ve PoWA 5.2.0 saglikli"

source_port="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW port')"
repo_port="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc 'SHOW port')"
[[ "$source_port" == "5432" ]] || fail "Kaynak portu 5432 degil: ${source_port}"
[[ "$repo_port" == "5433" ]] || fail "Repository portu 5433 degil: ${repo_port}"
pass "Iki PostgreSQL instance 5432 ve 5433 portlarinda"

source_ext="$(docker compose exec -T source-db psql -U postgres -d powa -Atqc \
  "SELECT string_agg(extname || '=' || extversion, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('powa','pg_stat_statements','btree_gist')")"
repo_ext="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT string_agg(extname || '=' || extversion, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('powa','pg_stat_statements','btree_gist')")"
[[ "$source_ext" == *"powa=5.2.0"* && "$source_ext" == *"pg_stat_statements="* ]] || fail "Kaynak extension seti eksik: ${source_ext}"
[[ "$repo_ext" == *"powa=5.2.0"* && "$repo_ext" == *"pg_stat_statements="* ]] || fail "Repository extension seti eksik: ${repo_ext}"
pass "Kaynak ve repository extension setleri dogru"

preload="$(docker compose exec -T source-db psql -U postgres -d appdb -Atqc 'SHOW shared_preload_libraries')"
[[ "$preload" == *"pg_stat_statements"* ]] || fail "pg_stat_statements preload edilmemis"
pass "Kaynak pg_stat_statements preload ayari dogru"

demo_server_id="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT id FROM \"PoWA\".powa_servers WHERE alias = 'test-source' AND hostname = 'source-db' AND port = 5432")"
[[ "$demo_server_id" =~ ^[0-9]+$ ]] || fail "test-source demo kaydi bulunamadi"
server_check="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -AtF '|' -qc \
  "SELECT retention = interval '90 days', password IS NULL FROM \"PoWA\".powa_servers WHERE id = ${demo_server_id}")"
all_passwords_null="$(docker compose exec -T repository-db psql -U postgres -p 5433 -d powa_repository -Atqc \
  'SELECT bool_and(password IS NULL) FROM "PoWA".powa_servers WHERE id > 0')"
[[ "$server_check" == "t|t" && "$all_passwords_null" == "t" ]] \
  || fail "Remote server/retention/parola kaydi hatali: demo=${server_check}, all_null=${all_passwords_null}"
pass "Demo kaydi, 90 gun retention ve tum kaynaklarda NULL parola dogru"

bash scripts/run-test-workload.sh 5 >/tmp/advisor-workload-result.txt
grep -q '"ok": true' /tmp/advisor-workload-result.txt || fail "Test fonksiyonu basarisiz"
pass "run_advisor_test_workload fonksiyonu calisti"

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

read -r server_id database_id query_id < <(python3 - <<'PY'
import json
with open('/tmp/advisor-queries-authorized.json', encoding='utf-8') as handle:
    data = json.load(handle)
assert data['total'] > 0, data
item = data['items'][0]
assert item['sqlVisible'] is True
assert item['calls'] > 0
assert 0 <= item['impactScore'] <= 100
print(item['serverId'], item['databaseId'], item['queryId'])
PY
)

python3 - <<'PY'
import json
with open('/tmp/advisor-queries-viewer.json', encoding='utf-8') as handle:
    data = json.load(handle)
assert data['items'], data
assert all(item['sqlVisible'] is False for item in data['items'])
assert all('analyst yetkisi' in item['sql'] for item in data['items'])
PY
pass "Sorgu API'si gercek metrik donuyor ve yetkisiz SQL maskeleniyor"

http_seconds="$(curl -fsS -o /tmp/advisor-performance.json -w '%{time_total}' \
  -H 'X-Advisor-Role: analyst' "${api_url}/api/v1/queries?window=24h&pageSize=50")"
python3 - "$http_seconds" <<'PY'
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
pass "API yalniz repository baglanti bilgisi tasiyor"

if docker compose ps --services --status running | grep -qx web; then
  curl -fsS "${web_url}/healthz" >/dev/null
  pass "Web arayuzu saglikli"
fi

echo
echo "Ilk iterasyon calisma zamani kabul kontrolleri tamamlandi."
