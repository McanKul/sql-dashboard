#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
warn() {
  printf '[UYARI] %s\n' "$1" >&2
  warning_count=$((warning_count + 1))
}
reject() {
  printf '[HATA] %s\n' "$1" >&2
  failure_count=$((failure_count + 1))
}
fatal() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "${script_dir}/.." && pwd -P)"
cd "$project_dir"

(( $# == 1 )) || fatal "Kullanim: $0 <workload-log-file>"
workload_log="$1"
failure_count=0
warning_count=0

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fatal "Workload JSON ve API yanitlarini dogrulamak icin Python 3 gerekli"
fi

command -v docker >/dev/null 2>&1 || fatal "docker bulunamadi"
docker info >/dev/null 2>&1 || fatal "Docker daemon calismiyor"

# Do not run a plain `docker compose` command here: a stack can have been
# started with a project name and one or more override files. Resolve the
# already-running project from Docker's Compose labels, then keep every check
# inside that exact project.
compose_project="${ADVISOR_COMPOSE_PROJECT:-${COMPOSE_PROJECT_NAME:-}}"
if [[ -z "$compose_project" ]]; then
  running_projects="$({
    docker ps \
      --filter label=com.docker.compose.service=source-db \
      --format '{{.Label "com.docker.compose.project"}}'
  } | sed '/^$/d' | sort -u)"
  project_count="$(printf '%s\n' "$running_projects" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$project_count" != "1" ]]; then
    fatal "Tek bir calisan advisor Compose projesi bulunamadi; ADVISOR_COMPOSE_PROJECT ayarlayin (bulunan: ${running_projects:-yok})"
  fi
  compose_project="$running_projects"
fi
[[ "$compose_project" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || fatal "Compose proje adi guvenli degil: ${compose_project}"

container_for() {
  local service="$1"
  local ids
  local count
  ids="$(docker ps \
    --filter "label=com.docker.compose.project=${compose_project}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}')"
  count="$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] \
    || fatal "${compose_project}/${service} icin tam bir calisan container bekleniyordu (bulunan: ${count})"
  printf '%s\n' "$ids"
}

source_container="$(container_for source-db)"
repository_container="$(container_for repository-db)"
collector_container="$(container_for collector)"
snapshotter_container="$(container_for join-snapshotter)"
api_container="$(container_for api)"

for service_and_container in \
  "source-db:${source_container}" \
  "repository-db:${repository_container}" \
  "collector:${collector_container}" \
  "join-snapshotter:${snapshotter_container}" \
  "api:${api_container}"; do
  service="${service_and_container%%:*}"
  container="${service_and_container#*:}"
  state="$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container")"
  if [[ "$state" == "running|healthy" || "$state" == "running|none" ]]; then
    pass "${compose_project}/${service} calisiyor (${state#*|})"
  else
    reject "${compose_project}/${service} saglikli degil: ${state}"
  fi
done

source_sql() {
  docker exec "$source_container" \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname appdb \
      --quiet --tuples-only --no-align --field-separator='|' --command "$1"
}

source_monitor_sql() {
  docker exec "$source_container" \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --dbname powa \
      --quiet --tuples-only --no-align --field-separator='|' --command "$1"
}

repository_sql() {
  docker exec "$repository_container" \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
      --dbname powa_repository --quiet --tuples-only --no-align --field-separator='|' \
      --command "$1"
}

source_alias="$(docker exec "$repository_container" printenv JOIN_SOURCE_ALIAS 2>/dev/null || true)"
source_alias="${source_alias:-test-source}"
[[ "$source_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$ ]] \
  || fatal "JOIN source alias guvenli degil: ${source_alias}"
server_state="$(repository_sql "SELECT id, frequency FROM \"PoWA\".powa_servers WHERE alias='${source_alias}'")"
IFS='|' read -r server_id source_frequency <<<"$server_state"
[[ "$server_id" =~ ^[0-9]+$ && "$source_frequency" =~ ^[0-9]+$ ]] \
  || fatal "${source_alias} PoWA server/frequency bulunamadi"
pass "Calisan Compose baglami sabitlendi: project=${compose_project}, source=${source_alias}/${server_id}, frequency=${source_frequency}s"

# The quick profile is the minimum accepted realistic data set. A supplied
# final report selects the exact normal/stress targets below. Every threshold
# remains overrideable for deliberately customized test hardware/data sets.
accepted_profile="${REALISTIC_PROFILE:-quick}"
report_profile=""
report_attempted=""
report_fingerprint_count=""

if [[ -n "$workload_log" ]]; then
  [[ -f "$workload_log" && -r "$workload_log" ]] \
    || fatal "Workload log okunamiyor: ${workload_log}"

  report_state="$($python_bin - "$workload_log" "${REALISTIC_MAX_ERROR_RATE:-0.01}" "${REALISTIC_MIN_ATTEMPTS:-100}" "${REALISTIC_MIN_OPERATIONS:-17}" <<'PY'
import json
import datetime as dt
import math
import pathlib
import re
import sys

path, max_error_rate, min_attempts, min_operations = sys.argv[1:]
max_error_rate = float(max_error_rate)
min_attempts = int(min_attempts)
min_operations = int(min_operations)
if not math.isfinite(max_error_rate) or not 0 <= max_error_rate <= 1:
    raise SystemExit("REALISTIC_MAX_ERROR_RATE 0..1 arasinda olmali")

final = None
with open(path, encoding="utf-8", errors="replace") as handle:
    for line_number, line in enumerate(handle, 1):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("type") == "advisor-realistic-final":
            final = value

if final is None:
    raise SystemExit("son advisor-realistic-final JSON summary bulunamadi")
if final.get("status") != "completed":
    raise SystemExit(f"workload status completed degil: {final.get('status')!r}")
profile = final.get("profile")
if profile not in {"quick", "normal", "stress"}:
    raise SystemExit(f"gecersiz workload profile: {profile!r}")

totals = final.get("totals")
if not isinstance(totals, dict):
    raise SystemExit("totals nesnesi yok")
attempted = totals.get("attempted")
succeeded = totals.get("succeeded")
failed = totals.get("failed")
error_rate = totals.get("errorRate")
if not all(type(value) in {int, float} for value in (attempted, succeeded, failed, error_rate)):
    raise SystemExit("attempted/succeeded/failed/errorRate sayisal degil")
attempted, succeeded, failed = int(attempted), int(succeeded), int(failed)
error_rate = float(error_rate)
if not math.isfinite(error_rate) or not 0 <= error_rate <= 1:
    raise SystemExit(f"errorRate gecersiz: {error_rate!r}")
if attempted < min_attempts:
    raise SystemExit(f"attempted={attempted}, minimum={min_attempts}")
if attempted != succeeded + failed:
    raise SystemExit("attempted != succeeded + failed")
calculated_rate = failed / attempted if attempted else 0.0
if not math.isclose(error_rate, calculated_rate, rel_tol=1e-6, abs_tol=1e-9):
    raise SystemExit(f"errorRate tutarsiz: json={error_rate}, hesap={calculated_rate}")
if error_rate > max_error_rate:
    raise SystemExit(f"errorRate={error_rate:.6f}, maksimum={max_error_rate:.6f}")
connection_errors = totals.get("connectionErrors")
if not isinstance(connection_errors, int) or connection_errors != 0:
    raise SystemExit(f"connectionErrors sifir degil: {connection_errors!r}")

duration = final.get("durationSeconds")
elapsed = final.get("elapsedSeconds")
workers = final.get("workers")
if not all(type(value) in {int, float} for value in (duration, elapsed, workers)):
    raise SystemExit("durationSeconds/elapsedSeconds/workers sayisal degil")
duration = float(duration)
elapsed = float(elapsed)
if not math.isfinite(duration) or not math.isfinite(elapsed):
    raise SystemExit("durationSeconds/elapsedSeconds sonlu degil")
max_overrun = max(60.0, duration * 0.10)
if not 30 <= duration <= 7200 or not duration * 0.95 <= elapsed <= duration + max_overrun:
    raise SystemExit(f"workload suresi gecersiz: duration={duration}, elapsed={elapsed}")
if not isinstance(workers, int) or not 3 <= workers <= 64:
    raise SystemExit("workers 3-64 arasinda tam sayi olmali")
if final.get("durationMode") != "bounded":
    raise SystemExit(f"workload durationMode bounded degil: {final.get('durationMode')!r}")

def parse_utc(value, label):
    if not isinstance(value, str) or not value:
        raise SystemExit(f"{label} UTC timestamp degil")
    try:
        parsed = dt.datetime.fromisoformat(
            value[:-1] + "+00:00" if value.endswith("Z") else value
        )
    except ValueError as exc:
        raise SystemExit(f"{label} parse edilemedi: {value!r}") from exc
    if parsed.tzinfo is None:
        raise SystemExit(f"{label} timezone icermiyor")
    return parsed.astimezone(dt.timezone.utc)

started_value = final.get("startedAt")
finished_value = final.get("finishedAt")
if started_value is not None or finished_value is not None:
    if started_value is None or finished_value is None:
        raise SystemExit("startedAt/finishedAt birlikte bulunmali")
    started_at = parse_utc(started_value, "startedAt")
    finished_at = parse_utc(finished_value, "finishedAt")
    window_source = "final-json"
else:
    # Older canonical reports predate explicit wall-clock fields. Accept only
    # the runner-authored UTC filename, and bind the end to the measured
    # elapsedSeconds. Arbitrary filenames fail closed instead of silently
    # falling back to a rolling repository window.
    match = re.fullmatch(
        r"(\d{8}T\d{6}Z)-(quick|normal|stress)\.log",
        pathlib.Path(path).name,
    )
    if match is None or match.group(2) != profile:
        raise SystemExit("timestamp alani yok ve canonical UTC report filename gecersiz")
    started_at = dt.datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(
        tzinfo=dt.timezone.utc
    )
    finished_at = started_at + dt.timedelta(seconds=float(elapsed))
    window_source = "canonical-filename"

wall_seconds = (finished_at - started_at).total_seconds()
if not duration * 0.95 <= wall_seconds <= duration + max_overrun:
    raise SystemExit(
        f"run wall-clock penceresi gecersiz: wall={wall_seconds}, duration={duration}"
    )
wall_elapsed_tolerance = max(10.0, elapsed * 0.05)
if abs(wall_seconds - elapsed) > wall_elapsed_tolerance:
    raise SystemExit(
        f"run wall-clock/elapsed tutarsiz: wall={wall_seconds}, elapsed={elapsed}"
    )
if finished_at > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
    raise SystemExit("finishedAt gelecekte")
started_at_text = started_at.isoformat(timespec="microseconds").replace("+00:00", "Z")
finished_at_text = finished_at.isoformat(timespec="microseconds").replace("+00:00", "Z")

role_workers = final.get("roleWorkers")
required_roles = {
    "advisor_workload_reader",
    "advisor_workload_writer",
    "advisor_workload_reporter",
}
if (
    not isinstance(role_workers, dict)
    or not required_roles.issubset(role_workers)
    or any(not isinstance(role_workers[role], int) or role_workers[role] < 1 for role in required_roles)
):
    raise SystemExit("reader/writer/reporter role worker dagilimi eksik")

categories = final.get("categories")
required_categories = {"read", "join", "cpu", "temp", "write", "lock"}
if not isinstance(categories, dict) or not required_categories.issubset(categories):
    raise SystemExit(f"workload kategori karmasi eksik: {sorted(categories) if isinstance(categories, dict) else []}")
category_totals = {"attempted": 0, "succeeded": 0, "failed": 0}
for category in required_categories:
    payload = categories[category]
    if not isinstance(payload, dict):
        raise SystemExit(f"workload kategori kaydi nesne degil: {category}")
    category_counts = tuple(payload.get(key) for key in category_totals)
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in category_counts):
        raise SystemExit(f"workload kategori sayaclari gecersiz: {category}")
    if category_counts[0] < 1 or category_counts[1] < 1:
        raise SystemExit(f"workload kategorisi calismadi: {category}")
    if category_counts[0] != category_counts[1] + category_counts[2]:
        raise SystemExit(f"workload kategori sayaclari tutarsiz: {category}")
    for key in category_totals:
        category_totals[key] += int(payload[key])
if category_totals != {"attempted": attempted, "succeeded": succeeded, "failed": failed}:
    raise SystemExit(f"kategori toplamlari totals ile tutarsiz: {category_totals}")

operations = final.get("operations")
if not isinstance(operations, dict) or len(operations) < min_operations:
    raise SystemExit(f"operation cesitliligi yetersiz: {len(operations) if isinstance(operations, dict) else 0}")
required_operations = {
    "claim-job",
    "controlled-lock",
    "cpu-order-rollup",
    "join-inventory-products",
    "join-orders-status",
    "join-orders-status-reader",
    "join-payments-orders",
    "read-customer-orders",
    "read-event-device",
    "read-inventory",
    "read-order-by-id",
    "read-ready-jobs",
    "temp-customer-rollup",
    "update-inventory",
    "update-order-lifecycle",
    "write-event",
    "write-mutation",
}
missing_operations = sorted(required_operations.difference(operations))
if missing_operations:
    raise SystemExit(f"beklenen workload operasyonlari eksik: {missing_operations}")
sql_template_count = final.get("sqlTemplateCount")
if not isinstance(sql_template_count, int) or isinstance(sql_template_count, bool) or sql_template_count < 27:
    raise SystemExit(f"SQL template kapsami yetersiz: {sql_template_count!r}, minimum=27")
fingerprints = []
operation_totals = {"attempted": 0, "succeeded": 0, "failed": 0}
for operation_name, operation in operations.items():
    if not isinstance(operation, dict):
        raise SystemExit(f"operation kaydi nesne degil: {operation_name}")
    operation_counts = tuple(operation.get(key) for key in operation_totals)
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in operation_counts):
        raise SystemExit(f"operation sayaclari gecersiz: {operation_name}")
    if operation_counts[0] < 1 or operation_counts[1] < 1:
        raise SystemExit(f"operation calismadi: {operation_name}")
    if operation_counts[0] != operation_counts[1] + operation_counts[2]:
        raise SystemExit(f"operation sayaclari tutarsiz: {operation_name}")
    for key in operation_totals:
        operation_totals[key] += int(operation[key])
    operation_fingerprints = operation.get("fingerprints")
    if not isinstance(operation_fingerprints, list) or not operation_fingerprints:
        raise SystemExit(f"operation fingerprint listesi eksik: {operation_name}")
    for fingerprint in operation_fingerprints:
        if not isinstance(fingerprint, str):
            raise SystemExit(f"sabit realistic fingerprint eksik: {fingerprint!r}")
        # Generator reports the stable logical tag (for example
        # `read-order-by-id`), while PostgreSQL sees the matching static SQL
        # comment. Accept the logical form and the fully rendered comment form.
        logical = fingerprint
        if "advisor-realistic:" in logical:
            logical = logical.split("advisor-realistic:", 1)[1].split()[0].rstrip("*/")
        if not logical or any(ch not in "abcdefghijklmnopqrstuvwxyz0123456789-" for ch in logical):
            raise SystemExit(f"gecersiz realistic fingerprint: {fingerprint!r}")
        fingerprints.append(logical)
unique_fingerprints = set(fingerprints)
if len(unique_fingerprints) < min_operations:
    raise SystemExit(f"benzersiz fingerprint cesitliligi yetersiz: {len(unique_fingerprints)}")
if operation_totals != {"attempted": attempted, "succeeded": succeeded, "failed": failed}:
    raise SystemExit(f"operation toplamlari totals ile tutarsiz: {operation_totals}")

database_delta = final.get("databaseDelta")
if not isinstance(database_delta, dict):
    raise SystemExit("databaseDelta nesnesi yok")
if int(database_delta.get("deadlocks") or 0) != 0:
    raise SystemExit(f"workload deadlock uretti: {database_delta.get('deadlocks')}")
if int(database_delta.get("xactCommit") or 0) <= 0:
    raise SystemExit("workload committed transaction uretmedi")
if int(database_delta.get("tempBytes") or 0) <= 0:
    raise SystemExit("workload tempBytes uretmedi")
if int(database_delta.get("walBytes") or 0) <= 0:
    raise SystemExit("workload walBytes uretmedi")
if database_delta.get("statsResetDetected") is not False:
    raise SystemExit("workload sirasinda stats reset algilandi")

print(
    f"{profile}|{attempted}|{succeeded}|{failed}|{error_rate:.8f}|"
    f"{len(unique_fingerprints)}|{int(database_delta.get('tempBytes') or 0)}|"
    f"{int(database_delta.get('walBytes') or 0)}|{started_at_text}|"
    f"{finished_at_text}|{window_source}"
)
PY
)" || fatal "Workload final JSON kabul edilmedi: ${report_state:-ayrinti yukarida}"

  IFS='|' read -r accepted_profile report_attempted report_succeeded report_failed \
    report_error_rate report_fingerprint_count report_temp_bytes report_wal_bytes \
    run_started_at run_finished_at run_window_source \
    <<<"$report_state"
  report_profile="$accepted_profile"
  pass "Final JSON: profile=${accepted_profile}, attempted=${report_attempted}, succeeded=${report_succeeded}, failed=${report_failed}, errorRate=${report_error_rate}, fingerprints=${report_fingerprint_count}"
  pass "Final JSON DB deltasi: temp=${report_temp_bytes} byte, WAL=${report_wal_bytes} byte, deadlock=0, stats-reset=false"
  pass "Current-run UTC penceresi: ${run_started_at} .. ${run_finished_at} (${run_window_source})"
else
  fatal "Current-run telemetry kabulunde workload log zorunlu"
fi

[[ "$run_started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ \
   && "$run_finished_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]] \
  || fatal "Current-run timestamp formati guvenli degil"

# Cumulative extension deltas are timestamped at the snapshot boundary, not at
# the instant the workload stops. Include exactly the first tagged repository
# snapshot after finishedAt; otherwise the final lock/kcache/wait interval would
# be subtracted as post-run data. The runner separately proves that a forced
# snapshot crossed the workload-end boundary.
telemetry_max_lag=$(( (source_frequency > 5 ? source_frequency : 5) * 3 + 10 ))
telemetry_finished_at=""
for telemetry_boundary_attempt in $(seq 1 20); do
  telemetry_finished_at="$(repository_sql "
SELECT coalesce(
  to_char(min(delta.sample_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'),
  ''
)
FROM advisor.query_deltas('${run_started_at}'::timestamptz) AS delta
JOIN \"PoWA\".powa_statements AS statement
  ON statement.srvid=delta.server_id
 AND statement.dbid=delta.database_id
 AND statement.queryid=delta.query_id
 AND statement.userid=delta.user_id
WHERE delta.server_id=${server_id}
  AND delta.sample_at > '${run_finished_at}'::timestamptz
  AND delta.sample_at <= '${run_finished_at}'::timestamptz
      + make_interval(secs => ${telemetry_max_lag})
  AND statement.query LIKE '%advisor-realistic:%';")"
  if [[ "$telemetry_finished_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]]; then
    break
  fi
  (( telemetry_boundary_attempt == 20 )) || sleep 3
done
[[ "$telemetry_finished_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ ]] \
  || fatal "Workload bitisinden sonraki ilk tagged repository snapshot'i bulunamadi"
pass "Current-run telemetry snapshot siniri: ${telemetry_finished_at} (maxLag=${telemetry_max_lag}s)"

manifest_state="$(source_sql "
SELECT
  status,
  profile,
  NOT EXISTS (
    SELECT 1
    FROM jsonb_each_text(target_counts) AS target(key, value)
    LEFT JOIN LATERAL (
      SELECT actual_counts ->> target.key AS value
    ) AS actual ON true
    WHERE actual.value IS NULL
       OR actual.value !~ '^[0-9]+$'
       OR target.value !~ '^[0-9]+$'
       OR actual.value::bigint < target.value::bigint
  ),
  target_counts ->> 'customers',
  target_counts ->> 'orders',
  target_counts ->> 'order_items',
  target_counts ->> 'events',
  target_counts ->> 'workload_tenants',
  target_counts ->> 'workload_customer_tenants',
  target_counts ->> 'workload_products',
  target_counts ->> 'workload_inventory',
  target_counts ->> 'workload_payments',
  target_counts ->> 'workload_jobs',
  target_counts ->> 'advisor_workload_hotspots',
  actual_counts ->> 'customers',
  actual_counts ->> 'orders',
  actual_counts ->> 'order_items',
  actual_counts ->> 'events',
  actual_counts ->> 'workload_tenants',
  actual_counts ->> 'workload_customer_tenants',
  actual_counts ->> 'workload_products',
  actual_counts ->> 'workload_inventory',
  actual_counts ->> 'workload_payments',
  actual_counts ->> 'workload_jobs',
  actual_counts ->> 'advisor_workload_hotspots'
FROM public.advisor_workload_seed_manifest
WHERE seed_key='active';")" || fatal "Seeder manifest'i okunamadi; once prepare-realistic-workload calistirin"
IFS='|' read -r manifest_status manifest_profile manifest_counts_ready \
  manifest_customers manifest_orders manifest_items manifest_events manifest_tenants \
  manifest_customer_tenants manifest_products manifest_inventory manifest_payments \
  manifest_jobs manifest_hotspots customers_count orders_count items_count events_count \
  tenants_count customer_tenants_count products_count inventory_count payments_count \
  jobs_count hotspots_count <<<"$manifest_state"
if [[ "$manifest_status" != "READY" || "$manifest_counts_ready" != "t" ]]; then
  fatal "Seeder manifest READY/target-complete degil: status=${manifest_status:-yok}, countsReady=${manifest_counts_ready:-yok}"
fi
if [[ -n "$report_profile" && "$report_profile" != "$manifest_profile" ]]; then
  fatal "Workload report profile'i seed manifest ile uyusmuyor: report=${report_profile}, manifest=${manifest_profile}"
fi
accepted_profile="$manifest_profile"
pass "Seeder manifest READY: profile=${accepted_profile}, actual_counts tum target_counts degerlerini karsiliyor"

case "$accepted_profile" in
  quick)
    default_customers=25000
    default_orders=250000
    default_items=750000
    default_events=1000000
    default_tenants=250
    default_customer_tenants=$default_customers
    default_products=25000
    default_inventory=50000
    default_payments=200000
    default_jobs=25000
    default_hotspots=64
    default_database_bytes=$((64 * 1024 * 1024))
    ;;
  normal)
    default_customers=100000
    default_orders=1000000
    default_items=4000000
    default_events=6000000
    default_tenants=1000
    default_customer_tenants=$default_customers
    default_products=100000
    default_inventory=200000
    default_payments=800000
    default_jobs=100000
    default_hotspots=64
    default_database_bytes=$((256 * 1024 * 1024))
    ;;
  stress)
    default_customers=250000
    default_orders=3000000
    default_items=12000000
    default_events=20000000
    default_tenants=2500
    default_customer_tenants=$default_customers
    default_products=250000
    default_inventory=500000
    default_payments=2400000
    default_jobs=250000
    default_hotspots=64
    default_database_bytes=$((768 * 1024 * 1024))
    ;;
  *) fatal "Gecersiz realistic profile: ${accepted_profile}" ;;
esac

min_customers="${REALISTIC_MIN_CUSTOMERS:-${manifest_customers:-$default_customers}}"
min_orders="${REALISTIC_MIN_ORDERS:-${manifest_orders:-$default_orders}}"
min_items="${REALISTIC_MIN_ORDER_ITEMS:-${manifest_items:-$default_items}}"
min_events="${REALISTIC_MIN_EVENTS:-${manifest_events:-$default_events}}"
min_tenants="${REALISTIC_MIN_TENANTS:-${manifest_tenants:-$default_tenants}}"
min_customer_tenants="${REALISTIC_MIN_CUSTOMER_TENANTS:-${manifest_customer_tenants:-$default_customer_tenants}}"
min_products="${REALISTIC_MIN_PRODUCTS:-${manifest_products:-$default_products}}"
min_inventory="${REALISTIC_MIN_INVENTORY:-${manifest_inventory:-$default_inventory}}"
min_payments="${REALISTIC_MIN_PAYMENTS:-${manifest_payments:-$default_payments}}"
min_jobs="${REALISTIC_MIN_JOBS:-${manifest_jobs:-$default_jobs}}"
min_hotspots="${REALISTIC_MIN_HOTSPOTS:-${manifest_hotspots:-$default_hotspots}}"
min_database_bytes="${REALISTIC_MIN_DATABASE_BYTES:-$default_database_bytes}"

database_bytes="$(source_sql "SELECT pg_database_size(current_database());")" \
  || fatal "Realistic database hacmi okunamadi"

check_minimum() {
  local label="$1"
  local actual="$2"
  local minimum="$3"
  if [[ "$actual" =~ ^[0-9]+$ && "$minimum" =~ ^[0-9]+$ ]] && (( actual >= minimum )); then
    pass "${label}: ${actual} (minimum ${minimum})"
  else
    reject "${label} yetersiz: ${actual:-okunamadi} (minimum ${minimum})"
  fi
}

check_minimum customers "$customers_count" "$min_customers"
check_minimum orders "$orders_count" "$min_orders"
check_minimum order_items "$items_count" "$min_items"
check_minimum events "$events_count" "$min_events"
check_minimum workload_tenants "$tenants_count" "$min_tenants"
check_minimum workload_customer_tenants "$customer_tenants_count" "$min_customer_tenants"
check_minimum workload_products "$products_count" "$min_products"
check_minimum workload_inventory "$inventory_count" "$min_inventory"
check_minimum workload_payments "$payments_count" "$min_payments"
check_minimum workload_jobs "$jobs_count" "$min_jobs"
check_minimum advisor_workload_hotspots "$hotspots_count" "$min_hotspots"
check_minimum "appdb byte hacmi" "$database_bytes" "$min_database_bytes"

role_and_stats_state="$(source_sql "
WITH expected_roles(role_name) AS (
  VALUES ('advisor_workload_reader'), ('advisor_workload_writer'), ('advisor_workload_reporter')
), seeded_tables(table_name) AS (
  VALUES ('customers'), ('orders'), ('order_items'), ('events'),
         ('workload_tenants'), ('workload_customer_tenants'),
         ('workload_products'), ('workload_inventory'),
         ('workload_payments'), ('workload_jobs'), ('advisor_workload_hotspots')
)
SELECT
  (SELECT count(*) FROM expected_roles e JOIN pg_roles r ON r.rolname=e.role_name),
  (SELECT count(*) FROM expected_roles e JOIN pg_roles r ON r.rolname=e.role_name WHERE NOT r.rolcanlogin),
  (SELECT count(*) FROM expected_roles e JOIN pg_roles r ON r.rolname=e.role_name
    WHERE pg_has_role('advisor_workload_login', r.oid, 'SET')),
  EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname='advisor_workload_login'
      AND rolcanlogin AND NOT rolsuper AND NOT rolinherit
      AND NOT rolcreatedb AND NOT rolcreaterole
      AND NOT rolreplication AND NOT rolbypassrls
  ),
  pg_has_role('advisor_workload_login', 'pg_read_all_stats', 'USAGE'),
  (SELECT count(*) FROM seeded_tables t JOIN pg_stat_user_tables s ON s.schemaname='public' AND s.relname=t.table_name
    WHERE s.n_live_tup > 0 AND COALESCE(s.last_analyze, s.last_autoanalyze) IS NOT NULL),
  (SELECT count(*) FROM pg_constraint WHERE contype='f' AND connamespace='public'::regnamespace AND NOT convalidated),
  NOT EXISTS (
    SELECT 1
    FROM public.advisor_workload_seed_manifest manifest
    CROSS JOIN LATERAL jsonb_each_text(manifest.target_counts) target(table_name, target_count)
    LEFT JOIN pg_stat_user_tables stats
      ON stats.schemaname='public' AND stats.relname=target.table_name
    WHERE manifest.seed_key='active'
      AND (stats.relname IS NULL OR stats.n_live_tup < target.target_count::bigint * 0.95)
  );")"
IFS='|' read -r role_count nologin_count settable_count login_secure stats_access \
  analyzed_count invalid_fk_count stats_counts_ok <<<"$role_and_stats_state"
if [[ "$role_count|$nologin_count|$settable_count|$login_secure|$stats_access" == "3|3|3|t|t" ]]; then
  pass "Düşük yetkili workload login'i ve üç NOLOGIN SET ROLE kimliği hazır"
else
  reject "Workload rol zarfi eksik: roles=${role_count}, nologin=${nologin_count}, settable=${settable_count}, loginSecure=${login_secure}, stats=${stats_access}"
fi
if [[ "$analyzed_count" == "11" ]]; then
  pass "On bir workload tablosu ANALYZE istatistigi tasiyor"
else
  reject "Seeder sonrasi ANALYZE kapsami eksik: ${analyzed_count}/11"
fi
if [[ "$stats_counts_ok" == "t" ]]; then
  pass "ANALYZE live-tuple tahminleri manifest hedeflerinin en az %95'inde"
else
  reject "Fiziksel tablo istatistikleri manifest hedeflerinden koptu"
fi
if [[ "$invalid_fk_count" == "0" ]]; then
  pass "Public foreign key constraint'lerinin tamami validated"
else
  reject "Validated olmayan foreign key bulundu: ${invalid_fk_count}"
fi

orphan_state="$(source_sql "
SELECT
  EXISTS (
    SELECT 1 FROM public.workload_customer_tenants link
    LEFT JOIN public.customers customer ON customer.id=link.customer_id
    LEFT JOIN public.workload_tenants tenant ON tenant.id=link.tenant_id
    WHERE customer.id IS NULL OR tenant.id IS NULL LIMIT 1
  ),
  EXISTS (
    SELECT 1 FROM public.workload_products product
    LEFT JOIN public.workload_tenants tenant ON tenant.id=product.tenant_id
    WHERE tenant.id IS NULL LIMIT 1
  ),
  EXISTS (
    SELECT 1 FROM public.workload_inventory inventory
    LEFT JOIN public.workload_products product ON product.id=inventory.product_id
    LEFT JOIN public.workload_tenants tenant ON tenant.id=inventory.tenant_id
    WHERE product.id IS NULL OR tenant.id IS NULL
       OR product.tenant_id <> inventory.tenant_id LIMIT 1
  ),
  EXISTS (
    SELECT 1 FROM public.workload_payments payment
    LEFT JOIN public.workload_tenants tenant ON tenant.id=payment.tenant_id
    LEFT JOIN public.orders orders_record ON orders_record.id=payment.order_id
    LEFT JOIN public.workload_customer_tenants mapping
      ON mapping.customer_id=orders_record.customer_id
    WHERE tenant.id IS NULL OR orders_record.id IS NULL OR mapping.customer_id IS NULL
       OR mapping.tenant_id <> payment.tenant_id LIMIT 1
  ),
  EXISTS (
    SELECT 1 FROM public.workload_jobs job
    LEFT JOIN public.workload_tenants tenant ON tenant.id=job.tenant_id
    WHERE tenant.id IS NULL LIMIT 1
  );")"
if [[ "$orphan_state" == "f|f|f|f|f" ]]; then
  pass "Customer/tenant/product/inventory/payment/job iliskilerinde orphan yok"
else
  reject "Realistic workload iliskilerinde orphan bulundu: ${orphan_state}"
fi

fingerprint_state="$(source_monitor_sql "
SELECT
  count(DISTINCT queryid),
  count(*) FILTER (WHERE calls > 0),
  coalesce(sum(calls), 0)::bigint
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname='appdb')
  AND query LIKE '%advisor-realistic:%';")"
IFS='|' read -r source_fingerprint_count active_fingerprint_count source_fingerprint_calls \
  <<<"$fingerprint_state"
default_min_fingerprints=7
if [[ "$report_fingerprint_count" =~ ^[0-9]+$ ]] && (( report_fingerprint_count > 1 )); then
  # The canonical join-orders-status SQL intentionally stays untagged so its
  # query identity remains compatible with the 2.7 replay fixture.
  default_min_fingerprints=$((report_fingerprint_count - 1))
fi
min_fingerprints="${REALISTIC_MIN_FINGERPRINTS:-$default_min_fingerprints}"
min_fingerprint_calls="${REALISTIC_MIN_FINGERPRINT_CALLS:-100}"
if [[ "$source_fingerprint_count" =~ ^[0-9]+$ && "$source_fingerprint_count" -ge "$min_fingerprints" \
   && "$active_fingerprint_count" =~ ^[0-9]+$ && "$active_fingerprint_count" -ge "$min_fingerprints" \
   && "$source_fingerprint_calls" =~ ^[0-9]+$ && "$source_fingerprint_calls" -ge "$min_fingerprint_calls" ]]; then
  pass "Source lifetime diagnostic: fingerprints=${source_fingerprint_count}, calls=${source_fingerprint_calls}"
else
  warn "Source lifetime diagnostic dusuk; hard gate current-run repository deltalaridir"
fi

canonical_join_state="$(repository_sql "
WITH run_calls AS (
  SELECT delta.query_id, delta.user_id, sum(delta.calls)::bigint AS calls
  FROM advisor.query_deltas('${run_started_at}'::timestamptz) AS delta
  JOIN \"PoWA\".powa_statements AS statement
    ON statement.srvid=delta.server_id
   AND statement.dbid=delta.database_id
   AND statement.queryid=delta.query_id
   AND statement.userid=delta.user_id
  WHERE delta.server_id=${server_id}
    AND delta.toplevel
    AND delta.sample_at >= '${run_started_at}'::timestamptz
    AND delta.sample_at <= '${telemetry_finished_at}'::timestamptz
    AND regexp_replace(btrim(statement.query), '[[:space:]]+', ' ', 'g') =
        'SELECT count(*) FROM public.customers AS c JOIN public.orders AS o ON o.customer_id = c.id WHERE o.status = \$1'
  GROUP BY delta.query_id, delta.user_id
), fingerprints AS (
  SELECT query_id, count(DISTINCT user_id)::bigint AS users, sum(calls)::bigint AS calls
  FROM run_calls
  GROUP BY query_id
)
SELECT
  count(*),
  count(*) FILTER (WHERE users >= 2 AND calls >= 20),
  coalesce(max(users) FILTER (WHERE users >= 2 AND calls >= 20),0),
  coalesce(max(calls) FILTER (WHERE users >= 2 AND calls >= 20),0)
FROM fingerprints;")"
IFS='|' read -r canonical_join_queryids canonical_multiuser_queryids \
  canonical_join_users canonical_join_calls \
  <<<"$canonical_join_state"
if [[ "$canonical_multiuser_queryids" =~ ^[0-9]+$ && "$canonical_multiuser_queryids" -ge 1 \
   && "$canonical_join_users" =~ ^[0-9]+$ && "$canonical_join_users" -ge 2 \
   && "$canonical_join_calls" =~ ^[0-9]+$ && "$canonical_join_calls" -ge 20 ]]; then
  pass "Current-run canonical 2.7 JOIN: ${canonical_join_users} rol, ${canonical_join_calls} call, queryIds=${canonical_join_queryids}"
else
  reject "Current-run canonical/multi-role JOIN eksik: queryIds=${canonical_join_queryids}, multiUser=${canonical_multiuser_queryids}, users=${canonical_join_users}, calls=${canonical_join_calls}"
fi

min_lock_samples="${REALISTIC_MIN_LOCK_SAMPLES:-10}"
telemetry_state=""
for telemetry_attempt in $(seq 1 20); do
  telemetry_state="$(repository_sql "
WITH bounds AS (
  SELECT '${run_started_at}'::timestamptz AS started_at,
         '${telemetry_finished_at}'::timestamptz AS finished_at
), all_metrics AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.query_metrics(statement_timestamp() - bounds.started_at) AS metric
  WHERE metric.server_id=${server_id}
    AND metric.sql_text LIKE '%advisor-realistic:%'
), post_metrics AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.query_metrics(
    greatest(
      statement_timestamp() - (bounds.finished_at + interval '1 microsecond'),
      interval '0 seconds'
    )
  ) AS metric
  WHERE metric.server_id=${server_id}
    AND metric.sql_text LIKE '%advisor-realistic:%'
), metrics AS (
  SELECT
    current_metric.query_id,
    greatest(current_metric.calls - coalesce(post_metric.calls,0),0)::bigint AS calls,
    coalesce(current_metric.cpu_user_time_ms,0) - coalesce(post_metric.cpu_user_time_ms,0) AS cpu_user_time_ms,
    coalesce(current_metric.cpu_system_time_ms,0) - coalesce(post_metric.cpu_system_time_ms,0) AS cpu_system_time_ms,
    coalesce(current_metric.cpu_total_time_ms,0) - coalesce(post_metric.cpu_total_time_ms,0) AS cpu_total_time_ms,
    coalesce(current_metric.filesystem_reads_bytes,0) - coalesce(post_metric.filesystem_reads_bytes,0) AS filesystem_reads_bytes,
    coalesce(current_metric.filesystem_writes_bytes,0) - coalesce(post_metric.filesystem_writes_bytes,0) AS filesystem_writes_bytes,
    coalesce(current_metric.wait_total_samples,0) - coalesce(post_metric.wait_total_samples,0) AS wait_total_samples,
    coalesce(current_metric.wait_io_samples,0) - coalesce(post_metric.wait_io_samples,0) AS wait_io_samples,
    coalesce(current_metric.wait_lock_samples,0) - coalesce(post_metric.wait_lock_samples,0) AS wait_lock_samples,
    coalesce(current_metric.wait_lwlock_samples,0) - coalesce(post_metric.wait_lwlock_samples,0) AS wait_lwlock_samples,
    coalesce(current_metric.wait_client_samples,0) - coalesce(post_metric.wait_client_samples,0) AS wait_client_samples,
    coalesce(current_metric.wait_ipc_samples,0) - coalesce(post_metric.wait_ipc_samples,0) AS wait_ipc_samples,
    coalesce(current_metric.wait_timeout_samples,0) - coalesce(post_metric.wait_timeout_samples,0) AS wait_timeout_samples,
    coalesce(current_metric.wait_activity_samples,0) - coalesce(post_metric.wait_activity_samples,0) AS wait_activity_samples,
    coalesce(current_metric.wait_extension_samples,0) - coalesce(post_metric.wait_extension_samples,0) AS wait_extension_samples,
    coalesce(current_metric.wait_other_samples,0) - coalesce(post_metric.wait_other_samples,0) AS wait_other_samples,
    greatest(current_metric.temp_blocks_written - coalesce(post_metric.temp_blocks_written,0),0)::bigint AS temp_blocks_written,
    greatest(current_metric.wal_bytes - coalesce(post_metric.wal_bytes,0),0)::numeric AS wal_bytes
  FROM all_metrics AS current_metric
  LEFT JOIN post_metrics AS post_metric
    USING (server_id, database_id, query_id)
), category_check AS (
  SELECT count(*) AS invalid_rows FROM metrics
  WHERE wait_total_samples < 0 OR wait_io_samples < 0 OR wait_lock_samples < 0
     OR wait_lwlock_samples < 0 OR wait_client_samples < 0 OR wait_ipc_samples < 0
     OR wait_timeout_samples < 0 OR wait_activity_samples < 0
     OR wait_extension_samples < 0 OR wait_other_samples < 0
     OR wait_io_samples + wait_lock_samples + wait_lwlock_samples + wait_client_samples
        + wait_ipc_samples + wait_timeout_samples + wait_activity_samples
        + wait_extension_samples + wait_other_samples <> wait_total_samples
)
SELECT
  count(*) FILTER (WHERE calls > 0),
  coalesce(sum(calls),0)::bigint,
  count(*) FILTER (WHERE calls > 0 AND cpu_total_time_ms > 0),
  round(coalesce(sum(cpu_total_time_ms),0)::numeric,3),
  count(*) FILTER (WHERE cpu_total_time_ms < 0 OR cpu_user_time_ms < 0 OR cpu_system_time_ms < 0),
  coalesce(sum(filesystem_reads_bytes),0)::bigint,
  coalesce(sum(filesystem_writes_bytes),0)::bigint,
  round(coalesce(sum(wait_lock_samples),0)::numeric,0),
  count(*) FILTER (
    WHERE wait_lock_samples > 0
      AND wait_lock_samples >= greatest(
        wait_io_samples, wait_lwlock_samples, wait_client_samples,
        wait_ipc_samples, wait_timeout_samples, wait_activity_samples,
        wait_extension_samples, wait_other_samples
      )
  ),
  round(coalesce(sum(wait_io_samples),0)::numeric,0),
  round(coalesce(sum(wait_timeout_samples),0)::numeric,0),
  (SELECT invalid_rows FROM category_check),
  coalesce(sum(temp_blocks_written),0)::bigint,
  round(coalesce(sum(wal_bytes),0)::numeric,0)
FROM metrics;")"
  IFS='|' read -r metric_fingerprints metric_calls kcache_rows cpu_total_ms negative_cpu_rows \
    filesystem_reads filesystem_writes lock_samples dominant_lock_rows io_wait_samples \
    timeout_samples invalid_wait_rows temp_blocks wal_bytes <<<"$telemetry_state"
  if [[ "$lock_samples" =~ ^[0-9]+$ ]] && (( lock_samples >= min_lock_samples )); then
    break
  fi
  if (( telemetry_attempt < 20 )); then
    printf '[BEKLE] Wait history aktarimi bekleniyor (%s/20, lockSamples=%s)\n' \
      "$telemetry_attempt" "${lock_samples:-okunamadi}"
    sleep 3
  fi
done

check_minimum "Current-run repository metric fingerprint" "$metric_fingerprints" "${REALISTIC_MIN_REPOSITORY_FINGERPRINTS:-$min_fingerprints}"
check_minimum "Current-run repository metric call" "$metric_calls" "${REALISTIC_MIN_REPOSITORY_CALLS:-100}"
check_minimum "Current-run pg_stat_kcache fingerprint" "$kcache_rows" "${REALISTIC_MIN_KCACHE_FINGERPRINTS:-3}"

if "$python_bin" - "$cpu_total_ms" "${REALISTIC_MIN_CPU_MS:-100}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
then
  pass "Current-run pg_stat_kcache execution CPU: ${cpu_total_ms} ms"
else
  reject "pg_stat_kcache CPU kaniti yetersiz: ${cpu_total_ms:-0} ms"
fi
if [[ "$negative_cpu_rows" == "0" ]]; then
  pass "pg_stat_kcache reset-safe; negatif CPU deltasi yok"
else
  reject "Negatif pg_stat_kcache CPU deltasi bulundu: ${negative_cpu_rows}"
fi
if [[ "$filesystem_reads" =~ ^[0-9]+$ && "$filesystem_writes" =~ ^[0-9]+$ \
   && $((filesystem_reads + filesystem_writes)) -gt 0 ]]; then
  pass "pg_stat_kcache filesystem I/O: read=${filesystem_reads}, write=${filesystem_writes} byte"
else
  warn "pg_stat_kcache filesystem byte sayaci sifir/null; platform page cache/rusage semantigi nedeniyle soft gate"
fi

check_minimum "Current-run pg_wait_sampling Lock sample" "$lock_samples" "$min_lock_samples"
if [[ "$lock_samples" =~ ^[0-9]+$ ]] && (( lock_samples > 0 )); then
  if [[ "$dominant_lock_rows" =~ ^[0-9]+$ ]] && (( dominant_lock_rows > 0 )); then
    pass "En az bir realistic fingerprintte dominant wait LOCK"
  else
    warn "Lock sample var ancak ayni kontrollu sorgudaki PgSleep daha dominant"
  fi
fi
if [[ "$invalid_wait_rows" == "0" ]]; then
  pass "Wait kategori toplami totalSamples ile tutarli"
else
  reject "Tutarsiz/negatif wait sample satiri bulundu: ${invalid_wait_rows}"
fi
if [[ "$io_wait_samples" =~ ^[0-9]+$ ]] && (( io_wait_samples > 0 )); then
  pass "pg_wait_sampling I/O kaniti: ${io_wait_samples} sample"
else
  warn "I/O wait sample olusmadi; host page cache nedeniyle bu sinyal soft gate'tir"
fi
if [[ "$timeout_samples" =~ ^[0-9]+$ ]] && (( timeout_samples > 0 )); then
  pass "Ek Timeout wait kaniti: ${timeout_samples} sample"
else
  warn "Timeout wait sample olusmadi; Lock sinyali hard gate olarak korundu"
fi
check_minimum "Temp block yazimi" "$temp_blocks" "1"
check_minimum "Query WAL byte" "$wal_bytes" "1"

freshness_state="$(repository_sql "
SELECT coalesce(
  extract(epoch FROM '${telemetry_finished_at}'::timestamptz - max(sample_at)),
  1e12
)::bigint
FROM advisor.kcache_deltas('${run_started_at}'::timestamptz)
WHERE server_id=${server_id}
  AND sample_at >= '${run_started_at}'::timestamptz
  AND sample_at <= '${telemetry_finished_at}'::timestamptz;")"
max_snapshot_lag=$(( (source_frequency > 5 ? source_frequency : 5) * 3 ))
if [[ "$freshness_state" =~ ^[0-9]+$ ]] && (( freshness_state <= max_snapshot_lag )); then
  pass "Current-run kcache son snapshot lag'i: ${freshness_state}s"
else
  reject "Current-run kcache snapshot lag'i siniri asti: lag=${freshness_state:-yok}s, limit=${max_snapshot_lag}s"
fi

predicate_state="$(repository_sql "
WITH bounds AS (
  SELECT '${run_started_at}'::timestamptz AS started_at,
         '${telemetry_finished_at}'::timestamptz AS finished_at
), all_filters AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.predicate_metrics(
    statement_timestamp() - bounds.started_at, ${server_id}, NULL, NULL
  ) AS metric
), post_filters AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.predicate_metrics(
    greatest(
      statement_timestamp() - (bounds.finished_at + interval '1 microsecond'),
      interval '0 seconds'
    ),
    ${server_id}, NULL, NULL
  ) AS metric
), filters AS (
  SELECT current_filter.*,
         current_filter.sample_count - coalesce(post_filter.sample_count,0) AS run_samples,
         current_filter.occurrences - coalesce(post_filter.occurrences,0) AS run_occurrences
  FROM all_filters AS current_filter
  LEFT JOIN post_filters AS post_filter
    USING (server_id, database_id, query_id, user_id, qual_id, relation_id)
  WHERE current_filter.table_name='orders'
    AND 'status'=ANY(current_filter.column_names)
    AND current_filter.sample_count - coalesce(post_filter.sample_count,0) >= 2
    AND current_filter.occurrences - coalesce(post_filter.occurrences,0) >= 5
), all_joins AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.join_predicate_metrics(
    statement_timestamp() - bounds.started_at, ${server_id}, NULL, NULL
  ) AS metric
), post_joins AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.join_predicate_metrics(
    greatest(
      statement_timestamp() - (bounds.finished_at + interval '1 microsecond'),
      interval '0 seconds'
    ),
    ${server_id}, NULL, NULL
  ) AS metric
), joins AS (
  SELECT current_join.*,
         current_join.sample_count - coalesce(post_join.sample_count,0) AS run_samples,
         current_join.occurrences - coalesce(post_join.occurrences,0) AS run_occurrences
  FROM all_joins AS current_join
  LEFT JOIN post_joins AS post_join
    USING (
      server_id, database_id, query_id, qual_id, qual_node_id,
      left_relation_id, left_attribute_number, right_relation_id,
      right_attribute_number, operator_oid
    )
  WHERE ((current_join.left_table_name='orders' AND current_join.left_column_name='customer_id'
          AND current_join.right_table_name='customers' AND current_join.right_column_name='id')
      OR (current_join.right_table_name='orders' AND current_join.right_column_name='customer_id'
          AND current_join.left_table_name='customers' AND current_join.left_column_name='id'))
    AND current_join.sample_count - coalesce(post_join.sample_count,0) >= 2
    AND current_join.occurrences - coalesce(post_join.occurrences,0) >= 5
), candidate_evidence AS (
  SELECT candidate.candidate_id,
         sum(evidence.join_occurrences)::bigint AS join_occurrences,
         sum(evidence.filter_occurrences)::bigint AS filter_occurrences,
         sum(evidence.rows_processed)::bigint AS rows_processed,
         sum(evidence.rows_filtered)::bigint AS rows_filtered,
         count(*)::bigint AS sample_count
  FROM bounds
  CROSS JOIN advisor.index_candidates AS candidate
  JOIN advisor.index_candidate_evidence AS evidence USING (candidate_id)
  WHERE candidate.server_id=${server_id}
    AND candidate.schema_name='public'
    AND candidate.table_name='orders'
    AND candidate.key_column_names=ARRAY['status','customer_id']::text[]
    AND evidence.captured_at >= bounds.started_at
    AND evidence.captured_at < bounds.finished_at
  GROUP BY candidate.candidate_id
), candidates AS (
  SELECT candidate.*,
         evidence.join_occurrences,
         evidence.filter_occurrences,
         evidence.rows_processed,
         evidence.rows_filtered,
         evidence.sample_count,
         least(1.0, greatest(
           0.0,
           evidence.rows_filtered::double precision / nullif(evidence.rows_processed,0)
         )) AS filter_ratio,
         CASE WHEN evidence.sample_count >= 3
                    AND evidence.join_occurrences >= 20
                    AND evidence.filter_occurrences >= 20
                    AND evidence.rows_filtered::double precision / nullif(evidence.rows_processed,0) >= 0.20
              THEN 'HIGH' ELSE 'LOW' END AS confidence,
         format(
           'CREATE INDEX CONCURRENTLY %I ON %I.%I USING btree (%I, %I);',
           'idx_advisor_' || left(regexp_replace(candidate.table_name, '[^a-zA-Z0-9_]+', '_', 'g'),24)
             || '_' || substr(replace(candidate.candidate_id::text,'-',''),1,8),
           candidate.schema_name, candidate.table_name,
           candidate.key_column_names[1], candidate.key_column_names[2]
         ) AS create_index_sql
  FROM advisor.index_candidates AS candidate
  JOIN candidate_evidence AS evidence USING (candidate_id)
  WHERE evidence.sample_count >= 2
    AND evidence.join_occurrences >= 5
    AND evidence.filter_occurrences >= 5
), best_candidate AS (
  SELECT * FROM candidates
  ORDER BY (confidence='HIGH') DESC,
           join_occurrences + filter_occurrences DESC,
           candidate_id
  LIMIT 1
)
SELECT
  (SELECT count(*) FROM filters),
  (SELECT count(*) FROM joins),
  (SELECT count(*) FROM candidates),
  coalesce((SELECT sample_count FROM best_candidate),0),
  coalesce((SELECT join_occurrences FROM best_candidate),0),
  coalesce((SELECT filter_occurrences FROM best_candidate),0),
  coalesce((SELECT filter_ratio FROM best_candidate),0),
  coalesce((SELECT confidence='HIGH' FROM best_candidate),false),
  coalesce((SELECT ordering_rule='SELECTIVE_EQUALITY_FILTER_THEN_JOIN' FROM best_candidate),false),
  coalesce((SELECT create_index_sql LIKE 'CREATE INDEX CONCURRENTLY %' FROM best_candidate),false);")"
IFS='|' read -r filter_rows join_rows candidate_rows candidate_samples candidate_join_occurrences \
  candidate_filter_occurrences candidate_filter_ratio high_confidence correct_ordering copyable_ddl \
  <<<"$predicate_state"
check_minimum "pg_qualstats WHERE/status kaniti" "$filter_rows" "1"
check_minimum "JOIN snapshot orders.customer_id=customers.id kaniti" "$join_rows" "1"
check_minimum "Persisted (status, customer_id) composite aday" "$candidate_rows" "1"
check_minimum "Composite sample boundary" "$candidate_samples" "3"
check_minimum "Composite JOIN occurrence" "$candidate_join_occurrences" "20"
check_minimum "Composite filter occurrence" "$candidate_filter_occurrences" "20"
if "$python_bin" - "$candidate_filter_ratio" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) >= 0.20 else 1)
PY
then
  pass "Composite filter seciciligi: ${candidate_filter_ratio}"
else
  reject "Composite filter seciciligi %20 altinda: ${candidate_filter_ratio:-0}"
fi
if [[ "$high_confidence|$correct_ordering|$copyable_ddl" == "t|t|t" ]]; then
  pass "Composite aday HIGH confidence, dogru kolon sirasi ve guvenli DDL taslagi tasiyor"
else
  reject "Composite aday sozlesmesi eksik: high=${high_confidence}, ordering=${correct_ordering}, ddl=${copyable_ddl}"
fi

health_state="$(repository_sql "
WITH collector AS (
  SELECT * FROM advisor.v_collector_health WHERE server_id=${server_id}
), joins AS (
  SELECT * FROM advisor.join_snapshot_capability(${server_id})
), ingest AS (
  SELECT * FROM advisor_ingest.join_source_status WHERE server_id=${server_id}
)
SELECT
  (SELECT status FROM collector),
  round((SELECT lag_seconds FROM collector)::numeric,3),
  (SELECT cardinality(errors) FROM collector),
  (SELECT frequency FROM collector),
  (SELECT status FROM joins),
  round((SELECT lag_seconds FROM joins)::numeric,3),
  coalesce((SELECT last_error IS NULL FROM ingest),false),
  coalesce(round(extract(epoch FROM ((SELECT last_ingest_at FROM ingest) - (SELECT last_capture_at FROM ingest)))::numeric,3),-1),
  (SELECT count(*) FROM advisor_ingest.join_snapshot_batches
    WHERE server_id=${server_id}
      AND captured_at >= '${run_started_at}'::timestamptz
      AND captured_at <= '${telemetry_finished_at}'::timestamptz),
  (SELECT count(*) FROM advisor_ingest.join_snapshot_batches
    WHERE server_id=${server_id}
      AND captured_at >= '${run_started_at}'::timestamptz
      AND captured_at <= '${telemetry_finished_at}'::timestamptz
      AND row_count > 0);")"
IFS='|' read -r collector_status collector_lag collector_errors source_frequency \
  join_status join_lag join_error_clear join_delivery_lag recent_batches recent_nonempty_batches \
  <<<"$health_state"

if [[ "$collector_status" == "HEALTHY" && "$collector_errors" == "0" ]]; then
  pass "Collector HEALTHY ve errors=0"
else
  reject "Collector sagligi bozuk: status=${collector_status}, errors=${collector_errors}"
fi
if "$python_bin" - "$collector_lag" "$source_frequency" <<'PY'
import sys
lag, frequency = map(float, sys.argv[1:])
raise SystemExit(0 if lag <= max(frequency, 5.0) * 3 else 1)
PY
then
  pass "Collector lag=${collector_lag}s (frequency=${source_frequency}s)"
else
  reject "Collector lag siniri asti: lag=${collector_lag}s, frequency=${source_frequency}s"
fi
if [[ "$join_status" == "HEALTHY" && "$join_error_clear" == "t" ]]; then
  pass "JOIN snapshotter HEALTHY ve last_error bos"
else
  reject "JOIN snapshotter sagligi bozuk: status=${join_status}, errorClear=${join_error_clear}"
fi
if "$python_bin" - "$join_lag" "$source_frequency" <<'PY'
import sys
lag, frequency = map(float, sys.argv[1:])
raise SystemExit(0 if lag <= max(frequency, 5.0) * 3 + 30.0 else 1)
PY
then
  pass "JOIN snapshot lag=${join_lag}s"
else
  reject "JOIN snapshot lag siniri asti: ${join_lag}s"
fi
if "$python_bin" - "$join_delivery_lag" <<'PY'
import sys
lag = float(sys.argv[1])
raise SystemExit(0 if 0 <= lag <= 30 else 1)
PY
then
  pass "JOIN capture->repository delivery lag=${join_delivery_lag}s"
else
  reject "JOIN teslim gecikmesi beklenmiyor: ${join_delivery_lag}s"
fi
check_minimum "Current-run JOIN batch" "$recent_batches" "3"
check_minimum "Current-run non-empty JOIN batch" "$recent_nonempty_batches" "3"

database_metric_state="$(repository_sql "
WITH bounds AS (
  SELECT '${run_started_at}'::timestamptz AS started_at,
         '${telemetry_finished_at}'::timestamptz AS finished_at
), all_metrics AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.database_io_metrics(
    statement_timestamp() - bounds.started_at
  ) AS metric
  WHERE metric.server_id=${server_id} AND metric.database_name='appdb'
), post_metrics AS (
  SELECT metric.*
  FROM bounds
  CROSS JOIN LATERAL advisor.database_io_metrics(
    greatest(
      statement_timestamp() - (bounds.finished_at + interval '1 microsecond'),
      interval '0 seconds'
    )
  ) AS metric
  WHERE metric.server_id=${server_id} AND metric.database_name='appdb'
)
SELECT
  greatest(current_metric.transactions_committed - coalesce(post_metric.transactions_committed,0),0),
  greatest(current_metric.temp_files - coalesce(post_metric.temp_files,0),0),
  greatest(current_metric.temp_bytes - coalesce(post_metric.temp_bytes,0),0),
  greatest(current_metric.deadlocks - coalesce(post_metric.deadlocks,0),0),
  greatest(current_metric.tuples_inserted - coalesce(post_metric.tuples_inserted,0),0),
  greatest(current_metric.tuples_updated - coalesce(post_metric.tuples_updated,0),0),
  greatest(current_metric.tuples_deleted - coalesce(post_metric.tuples_deleted,0),0)
FROM all_metrics AS current_metric
LEFT JOIN post_metrics AS post_metric USING (server_id, database_id);")"
IFS='|' read -r committed temp_files temp_bytes deadlocks tuples_inserted tuples_updated tuples_deleted \
  <<<"$database_metric_state"
check_minimum "Committed transaction" "$committed" "1"
check_minimum "Database temp file" "$temp_files" "1"
check_minimum "Database temp byte" "$temp_bytes" "1"
if [[ "$deadlocks" == "0" ]]; then
  pass "Database deadlock deltasi sifir"
else
  reject "Workload penceresinde deadlock bulundu: ${deadlocks}"
fi
check_minimum "Inserted tuple" "$tuples_inserted" "1"
check_minimum "Updated tuple" "$tuples_updated" "1"
check_minimum "Deleted tuple" "$tuples_deleted" "1"

api_state="$(docker exec -i \
  -e REALISTIC_API_SAMPLES="${REALISTIC_API_SAMPLES:-20}" \
  -e REALISTIC_SERVER_ID="$server_id" \
  "$api_container" python - <<'PY'
import json
import math
import os
import time
import urllib.request

samples = int(os.environ["REALISTIC_API_SAMPLES"])
server_id = int(os.environ["REALISTIC_SERVER_ID"])
if not 20 <= samples <= 100:
    raise SystemExit("REALISTIC_API_SAMPLES must be 20..100")
if server_id < 1:
    raise SystemExit("REALISTIC_SERVER_ID must be positive")

with urllib.request.urlopen("http://127.0.0.1:8000/api/v1/health", timeout=5) as response:
    health = json.load(response)
if health.get("repository") != "healthy":
    raise SystemExit(f"API health repository unhealthy: {health}")

query_url = (
    "http://127.0.0.1:8000/api/v1/queries"
    f"?window=1h&pageSize=50&serverId={server_id}"
)
request = urllib.request.Request(
    query_url,
    headers={"X-Advisor-Role": "analyst"},
)
# Exclude connection-pool/query-cache warm-up from the timed distribution.
with urllib.request.urlopen(request, timeout=5) as response:
    warmup = json.load(response)
if not warmup.get("items"):
    raise SystemExit("target source API warm-up returned no query items")

times = []
total_items = 0
for _ in range(samples):
    request = urllib.request.Request(
        query_url,
        headers={"X-Advisor-Role": "analyst"},
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=5) as response:
        payload = json.load(response)
    times.append(time.perf_counter() - started)
    total_items += len(payload.get("items") or [])

ordered = sorted(times)
p95 = ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]
print(f"{p95:.6f}|{max(times):.6f}|{samples}|{total_items}")
PY
)" || fatal "API health/latency probe'u calismadi"
IFS='|' read -r api_p95 api_max api_samples api_total_items <<<"$api_state"
if "$python_bin" - "$api_p95" "${REALISTIC_MAX_API_P95_SECONDS:-2.0}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
then
  pass "API ${api_samples} ornek p95=${api_p95}s, max=${api_max}s"
else
  reject "API p95 hedefi asildi: ${api_p95}s (limit ${REALISTIC_MAX_API_P95_SECONDS:-2.0}s)"
fi
check_minimum "API toplam query item" "$api_total_items" "$api_samples"

printf '\nRealistic workload kabul ozeti: hard_failures=%s, warnings=%s\n' \
  "$failure_count" "$warning_count"
if (( failure_count > 0 )); then
  exit 1
fi
pass "Realistic toplu workload DB/telemetri kabulunun tum hard gate'leri gecti"
