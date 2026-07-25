#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Kullanim:
  bash scripts/prepare-realistic-workload.sh <quick|normal|stress> --yes

Bu opt-in komut yalniz calisan source-db/appdb verisini secilen hedefe kadar
buyutur. Satir silmez, volume temizlemez ve init-source.sh dosyasini kullanmaz.
COMPOSE_PROJECT_NAME ve COMPOSE_FILE mevcut shell ortamindan aynen devralinir.
EOF
}

fail() {
  printf 'HATA: %s\n' "$*" >&2
  exit 1
}

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " ");
    value = bytes + 0;
    unit = 1;
    while (value >= 1024 && unit < 5) {
      value /= 1024;
      unit++;
    }
    printf "%.1f %s", value, units[unit];
  }'
}

if (( $# != 2 )); then
  usage
  exit 2
fi

profile="$1"
confirmation="$2"
[[ "$confirmation" == "--yes" ]] || fail "Acik onay gerekli: ikinci arguman --yes olmali."

case "$profile" in
  quick)
    target_customers=25000
    target_orders=250000
    target_order_items=750000
    target_events=1000000
    target_tenants=250
    target_products=25000
    target_inventory=50000
    target_payments=200000
    target_jobs=25000
    batch_size=25000
    ;;
  normal)
    target_customers=100000
    target_orders=1000000
    target_order_items=4000000
    target_events=6000000
    target_tenants=1000
    target_products=100000
    target_inventory=200000
    target_payments=800000
    target_jobs=100000
    batch_size=100000
    ;;
  stress)
    target_customers=250000
    target_orders=3000000
    target_order_items=12000000
    target_events=20000000
    target_tenants=2500
    target_products=250000
    target_inventory=500000
    target_payments=2400000
    target_jobs=250000
    batch_size=250000
    ;;
  *)
    usage
    exit 2
    ;;
esac

target_hotspots=64

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
seed_file="$repo_root/deployment/workload/seed.sql"
[[ -r "$seed_file" ]] || fail "Seeder okunamiyor: $seed_file"

command -v docker >/dev/null 2>&1 || fail "docker komutu bulunamadi."
docker info >/dev/null 2>&1 || fail "Docker daemon erisilebilir degil."

cd "$repo_root"
docker compose config --quiet
docker compose --profile realistic-load config --quiet

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fail "Compose workload parolasini cozumlemek icin Python 3 gerekli."
fi

# Read the fully resolved value that Compose will pass to the workload service.
# This covers shell variables and .env/COMPOSE_ENV_FILES without sourcing an
# operator-controlled env file as shell code.
if ! workload_db_password="$(
  docker compose --profile realistic-load config --format json \
    | "$python_bin" -c \
      'import json, sys; print(json.load(sys.stdin)["services"]["workload"]["environment"]["PGPASSWORD"], end="")'
)"; then
  fail "Compose workload parolasi cozumlenemedi."
fi
(( ${#workload_db_password} >= 16 )) \
  || fail "WORKLOAD_DB_PASSWORD en az 16 karakter olmali."
case "$workload_db_password" in
  advisor_dev_workload|change-me-workload|change-me-*)
    fail "WORKLOAD_DB_PASSWORD bilinen ornek/gelistirme degeri olamaz."
    ;;
esac
export WORKLOAD_DB_PASSWORD="$workload_db_password"
if ! compose_project_name="$(
  docker compose --profile realistic-load config --format json \
    | "$python_bin" -c \
      'import json, sys; print(json.load(sys.stdin)["name"], end="")'
)"; then
  fail "Compose proje adi cozumlenemedi."
fi
[[ "$compose_project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || fail "Compose proje adi guvenli degil: $compose_project_name"

running_services="$(docker compose ps --services --status running)"
grep -qx 'source-db' <<<"$running_services" || fail "Secili Compose context'inde source-db calismiyor."
if grep -qx 'workload' <<<"$running_services"; then
  fail "Seed sirasinda workload servisi calismamali; once kontrollu olarak durdurun."
fi

source_container="$(docker compose ps -q source-db)"
[[ -n "$source_container" ]] || fail "source-db container kimligi bulunamadi."
source_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$source_container")"
[[ "$source_health" == "healthy" ]] || fail "source-db healthy degil: $source_health"

source_guard="$(docker compose exec -T source-db \
  psql -X -U postgres -d appdb -AtF '|' -v ON_ERROR_STOP=1 -c \
  "SELECT current_database(),
          COALESCE(current_setting('advisor.validation_clone', true), ''),
          to_regclass('public.customers') IS NOT NULL,
          to_regclass('public.orders') IS NOT NULL,
          to_regclass('public.order_items') IS NOT NULL,
          to_regclass('public.events') IS NOT NULL")"
IFS='|' read -r source_database clone_marker has_customers has_orders has_items has_events <<<"$source_guard"
[[ "$source_database" == "appdb" ]] || fail "Beklenmeyen hedef database: $source_database"
[[ "$clone_marker" != "on" ]] || fail "Validation clone uzerinde seed reddedildi."
[[ "$has_customers|$has_orders|$has_items|$has_events" == "t|t|t|t" ]] \
  || fail "Baz appdb tablolari eksik; normal init-source bootstrap gerekli."

current_db_bytes="$(docker compose exec -T source-db \
  psql -X -U postgres -d appdb -Atqc "SELECT pg_database_size(current_database())")"
available_bytes="$(docker compose exec -T source-db \
  sh -c "df -Pk /var/lib/postgresql | awk 'NR == 2 {print \$4 * 1024}'")"
[[ "$current_db_bytes" =~ ^[0-9]+$ ]] || fail "Mevcut database boyutu okunamadi."
[[ "$available_bytes" =~ ^[0-9]+$ ]] || fail "Volume bos alan bilgisi okunamadi."

source_table_count() {
  local relation_name="$1"
  local relation_exists
  [[ "$relation_name" =~ ^[a-z][a-z0-9_]*$ ]] \
    || fail "Guvenli olmayan relation adi: $relation_name"
  relation_exists="$(docker compose exec -T source-db \
    psql -X -U postgres -d appdb -Atqc \
    "SELECT to_regclass('public.${relation_name}') IS NOT NULL")"
  if [[ "$relation_exists" == "f" ]]; then
    printf '0'
    return
  fi
  [[ "$relation_exists" == "t" ]] \
    || fail "Relation varligi okunamadi: $relation_name"
  docker compose exec -T source-db \
    psql -X -U postgres -d appdb -Atqc \
    "SET statement_timeout = '120s'; SELECT count(*) FROM public.${relation_name}"
}

missing_rows() {
  local target_rows="$1"
  local current_rows="$2"
  if (( target_rows > current_rows )); then
    printf '%s' "$((target_rows - current_rows))"
  else
    printf '0'
  fi
}

current_customers="$(source_table_count customers)"
current_orders="$(source_table_count orders)"
current_order_items="$(source_table_count order_items)"
current_events="$(source_table_count events)"
current_tenants="$(source_table_count workload_tenants)"
current_customer_tenants="$(source_table_count workload_customer_tenants)"
current_products="$(source_table_count workload_products)"
current_inventory="$(source_table_count workload_inventory)"
current_payments="$(source_table_count workload_payments)"
current_jobs="$(source_table_count workload_jobs)"
current_hotspots="$(source_table_count advisor_workload_hotspots)"

for count_value in \
  "$current_customers" "$current_orders" "$current_order_items" "$current_events" \
  "$current_tenants" "$current_customer_tenants" "$current_products" \
  "$current_inventory" "$current_payments" "$current_jobs" "$current_hotspots"; do
  [[ "$count_value" =~ ^[0-9]+$ ]] || fail "Tablo satir sayisi okunamadi."
done

missing_customers="$(missing_rows "$target_customers" "$current_customers")"
missing_orders="$(missing_rows "$target_orders" "$current_orders")"
missing_order_items="$(missing_rows "$target_order_items" "$current_order_items")"
missing_events="$(missing_rows "$target_events" "$current_events")"
missing_tenants="$(missing_rows "$target_tenants" "$current_tenants")"
missing_customer_tenants="$(missing_rows "$target_customers" "$current_customer_tenants")"
missing_products="$(missing_rows "$target_products" "$current_products")"
missing_inventory="$(missing_rows "$target_inventory" "$current_inventory")"
missing_payments="$(missing_rows "$target_payments" "$current_payments")"
missing_jobs="$(missing_rows "$target_jobs" "$current_jobs")"
missing_hotspots="$(missing_rows "$target_hotspots" "$current_hotspots")"

# Estimate only missing rows in the managed workload relations. Unrelated appdb
# objects and bloat therefore cannot mask the required growth. The result is
# doubled for WAL/index/temp headroom and receives a fixed 2 GiB safety margin.
estimated_growth_bytes=$((
    missing_customers * 224
  + missing_orders * 320
  + missing_order_items * 192
  + missing_events * 384
  + missing_tenants * 512
  + missing_customer_tenants * 96
  + missing_products * 384
  + missing_inventory * 160
  + missing_payments * 320
  + missing_jobs * 320
  + missing_hotspots * 128
))
required_free_bytes=$((estimated_growth_bytes * 2 + 2 * 1024 * 1024 * 1024))

printf 'Realistic workload seed plani\n'
printf '  Compose project : %s\n' "$compose_project_name"
printf '  Compose files   : %s\n' "${COMPOSE_FILE:-compose.yaml}"
printf '  Profil          : %s\n' "$profile"
printf '  Mevcut appdb    : %s\n' "$(human_bytes "$current_db_bytes")"
printf '  Bos disk        : %s\n' "$(human_bytes "$available_bytes")"
printf '  Gerekli headroom: %s\n' "$(human_bytes "$required_free_bytes")"
printf '  Hedefler        : customers=%s orders=%s items=%s events=%s\n' \
  "$target_customers" "$target_orders" "$target_order_items" "$target_events"
printf '                    tenants=%s products=%s inventory=%s payments=%s jobs=%s hotspots=%s\n' \
  "$target_tenants" "$target_products" "$target_inventory" \
  "$target_payments" "$target_jobs" "$target_hotspots"
printf '  Eksik satirlar  : customers=%s orders=%s items=%s events=%s\n' \
  "$missing_customers" "$missing_orders" "$missing_order_items" "$missing_events"
printf '                    tenants=%s mappings=%s products=%s inventory=%s payments=%s jobs=%s hotspots=%s\n' \
  "$missing_tenants" "$missing_customer_tenants" "$missing_products" \
  "$missing_inventory" "$missing_payments" "$missing_jobs" "$missing_hotspots"

(( available_bytes >= required_free_bytes )) || fail \
  "Disk preflight basarisiz: en az $(human_bytes "$required_free_bytes") bos alan gerekli."

started_seconds=$SECONDS
printf '\nBatch seed basliyor; mevcut satirlar korunacak ve yalniz hedefe eksik kisim eklenecek.\n'

docker compose exec -T -e WORKLOAD_DB_PASSWORD source-db \
  psql -X -U postgres -d appdb -v ON_ERROR_STOP=1 \
  -v seed_profile="$profile" \
  -v batch_size="$batch_size" \
  -v target_customers="$target_customers" \
  -v target_orders="$target_orders" \
  -v target_order_items="$target_order_items" \
  -v target_events="$target_events" \
  -v target_tenants="$target_tenants" \
  -v target_products="$target_products" \
  -v target_inventory="$target_inventory" \
  -v target_payments="$target_payments" \
  -v target_jobs="$target_jobs" \
  -v target_hotspots="$target_hotspots" \
  < "$seed_file"

manifest_row="$(docker compose exec -T source-db \
  psql -X -U postgres -d appdb -AtF '|' -v ON_ERROR_STOP=1 -c \
  "SELECT profile,
          status,
          actual_counts ->> 'customers',
          actual_counts ->> 'orders',
          actual_counts ->> 'order_items',
          actual_counts ->> 'events',
          actual_counts ->> 'workload_tenants',
          actual_counts ->> 'workload_products',
          actual_counts ->> 'workload_inventory',
          actual_counts ->> 'workload_payments',
          actual_counts ->> 'workload_jobs',
          actual_counts ->> 'advisor_workload_hotspots',
          pg_size_pretty(pg_database_size(current_database()))
   FROM advisor_workload_seed_manifest
   WHERE seed_key = 'active'")"

IFS='|' read -r actual_profile manifest_status \
  actual_customers actual_orders actual_items actual_events actual_tenants \
  actual_products actual_inventory actual_payments actual_jobs actual_hotspots \
  final_db_size <<<"$manifest_row"

[[ "$actual_profile" == "$profile" ]] || fail "Manifest profil uyusmazligi: $actual_profile"
[[ "$manifest_status" == "READY" ]] || fail "Manifest READY degil: $manifest_status"

elapsed_seconds=$((SECONDS - started_seconds))
printf '\nSeed ve guvenli dogrulama tamamlandi (%ss).\n' "$elapsed_seconds"
printf '  appdb boyutu : %s\n' "$final_db_size"
printf '  Baz tablolar  : customers=%s orders=%s items=%s events=%s\n' \
  "$actual_customers" "$actual_orders" "$actual_items" "$actual_events"
printf '  Yardimci      : tenants=%s products=%s inventory=%s payments=%s jobs=%s hotspots=%s\n' \
  "$actual_tenants" "$actual_products" "$actual_inventory" \
  "$actual_payments" "$actual_jobs" "$actual_hotspots"
printf '  Manifest      : public.advisor_workload_seed_manifest (%s)\n' "$manifest_status"
printf '\nHicbir satir/volume silinmedi. Ayni profil tekrar calistirilirsa target-count nedeniyle yeni kopya uretmez.\n'
