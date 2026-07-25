#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "${script_dir}/.." && pwd -P)"
cd "$project_dir"

profile="${1:-normal}"
duration="${2:-}"
workers="${3:-}"

case "$profile" in
  quick)
    duration="${duration:-120}"
    workers="${workers:-8}"
    ;;
  normal)
    duration="${duration:-600}"
    workers="${workers:-24}"
    ;;
  stress)
    duration="${duration:-1800}"
    workers="${workers:-48}"
    ;;
  *)
    fail "Kullanim: $0 [quick|normal|stress] [sure-saniye] [worker]"
    ;;
esac

if ! [[ "$duration" =~ ^[0-9]+$ ]] \
   || (( duration < 30 || duration > 7200 )); then
  fail "Sure 30-7200 saniye arasinda olmali"
fi
if ! [[ "$workers" =~ ^[0-9]+$ ]] \
   || (( workers < 3 || workers > 64 )); then
  fail "Worker 3-64 arasinda olmali (reader/writer/reporter icin en az birer worker)"
fi

command -v docker >/dev/null 2>&1 || fail "Docker bulunamadi"
if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fail "Workload run zamanini guvenli JSON'a eklemek icin Python 3 gerekli"
fi

# Reuse the one already-running advisor project instead of accidentally
# addressing Compose's default project name. Explicit caller settings always
# win; otherwise Docker's immutable Compose labels provide project/config paths.
if [[ -n "${ADVISOR_COMPOSE_PROJECT:-}" ]]; then
  export COMPOSE_PROJECT_NAME="$ADVISOR_COMPOSE_PROJECT"
fi
if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
  running_projects="$(
    docker ps --filter label=com.docker.compose.service=source-db \
      --format '{{.Label "com.docker.compose.project"}}' | sed '/^$/d' | sort -u
  )"
  project_count="$(printf '%s\n' "$running_projects" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$project_count" == "1" ]] \
    || fail "Tek bir calisan advisor projesi bulunamadi; COMPOSE_PROJECT_NAME ayarlayin"
  export COMPOSE_PROJECT_NAME="$running_projects"
fi
[[ "$COMPOSE_PROJECT_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || fail "Compose proje adi guvenli degil: ${COMPOSE_PROJECT_NAME}"

if [[ -z "${COMPOSE_FILE:-}" ]]; then
  source_container="$(
    docker ps \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
      --filter label=com.docker.compose.service=source-db \
      --format '{{.ID}}' | head -n 1
  )"
  [[ -n "$source_container" ]] \
    || fail "Secili Compose projesinde calisan source-db bulunamadi"
  config_files="$(
    docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
      "$source_container"
  )"
  [[ -n "$config_files" ]] || fail "Calisan Compose config dosyalari bulunamadi"
  export COMPOSE_FILE="${config_files//,/:}"
fi

docker compose --profile realistic-load config --quiet

required_services=(source-db repository-db collector join-snapshotter api evaluator)
for service in "${required_services[@]}"; do
  service_id="$(docker compose --profile realistic-load ps --quiet --status running "$service")"
  [[ -n "$service_id" ]] || fail "${service} calismiyor; once ana stack'i baslatin"
  service_health="$(
    docker inspect --format \
      '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$service_id"
  )"
  [[ "$service_health" == "healthy" ]] \
    || fail "${service} healthy degil: ${service_health}"
done
pass "Kaynak, repository, collector, snapshotter, API ve evaluator healthy"

bash scripts/prepare-realistic-workload.sh "$profile" --yes

if [[ "${REALISTIC_SKIP_BUILD:-false}" != "true" ]]; then
  docker compose --profile realistic-load build workload
fi
pass "Realistic workload image'i hazir"

source_alias="$(docker compose exec -T repository-db printenv JOIN_SOURCE_ALIAS 2>/dev/null)" \
  || fail "Repository container JOIN_SOURCE_ALIAS degeri okunamadi"
[[ "$source_alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$ ]] \
  || fail "JOIN source alias guvenli degil: ${source_alias}"
server_id="$(
  docker compose exec -T repository-db \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
      --dbname powa_repository --tuples-only --no-align \
      --command "SELECT id FROM \"PoWA\".powa_servers WHERE alias='${source_alias}'"
)"
[[ "$server_id" =~ ^[0-9]+$ ]] || fail "PoWA source server id bulunamadi"

mkdir -p runtime/load-reports
started_at="$(date -u +%Y%m%dT%H%M%SZ)"
fallback_started_at="${started_at:0:4}-${started_at:4:2}-${started_at:6:2}T${started_at:9:2}:${started_at:11:2}:${started_at:13:2}Z"
report_file="runtime/load-reports/${started_at}-${profile}.log"

printf 'Realistic workload basliyor: profile=%s duration=%ss workers=%s\n' \
  "$profile" "$duration" "$workers"
docker compose --profile realistic-load run --rm --no-deps \
  -e WORKLOAD_PROFILE="$profile" \
  -e WORKLOAD_DURATION_SECONDS="$duration" \
  -e WORKLOAD_WORKERS="$workers" \
  -e WORKLOAD_INTERVAL_SECONDS="${WORKLOAD_INTERVAL_SECONDS:-0.02}" \
  -e WORKLOAD_REPORT_INTERVAL_SECONDS="${WORKLOAD_REPORT_INTERVAL_SECONDS:-10}" \
  -e WORKLOAD_RANDOM_SEED="${WORKLOAD_RANDOM_SEED:-20260725}" \
  -e WORKLOAD_STATEMENT_TIMEOUT_MS="${WORKLOAD_STATEMENT_TIMEOUT_MS:-15000}" \
  -e WORKLOAD_LOCK_TIMEOUT_MS="${WORKLOAD_LOCK_TIMEOUT_MS:-5000}" \
  -e WORKLOAD_LOCK_HOLD_MS="${WORKLOAD_LOCK_HOLD_MS:-75}" \
  workload \
  | "$python_bin" -u -c '
import datetime as dt
import json
import sys

fallback_started_at = sys.argv[1]
observed_started_at = None

def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")

for raw_line in sys.stdin:
    line = raw_line.rstrip("\n")
    rendered = line
    try:
        payload = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        payload = None
    if isinstance(payload, dict) and payload.get("type") == "advisor-realistic-start":
        observed_started_at = payload.get("startedAt") or utc_now()
        payload.setdefault("startedAt", observed_started_at)
        rendered = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    elif isinstance(payload, dict) and payload.get("type") == "advisor-realistic-final":
        payload.setdefault("startedAt", observed_started_at or fallback_started_at)
        payload.setdefault("finishedAt", utc_now())
        rendered = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    print(rendered, flush=True)
' "$fallback_started_at" \
  | tee "$report_file"
pass "Karma workload hatasiz tamamlandi; ham rapor: ${report_file}"

# Final JSON'daki generator zamanini snapshot kapisinin ayni run'a ait olmasi
# icin kullan. Bu deger verifier tarafinda da yeniden ve daha ayrintili kontrol
# edilir; burada yalniz guvenli UTC parse + epoch microsecond elde ediyoruz.
run_end_state="$($python_bin - "$report_file" <<'PY'
import datetime as dt
import json
import sys

final = None
with open(sys.argv[1], encoding="utf-8", errors="strict") as handle:
    for line in handle:
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and candidate.get("type") == "advisor-realistic-final":
            final = candidate
if final is None or not isinstance(final.get("finishedAt"), str):
    raise SystemExit("timestamped final workload JSON bulunamadi")
value = final["finishedAt"]
parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
if parsed.tzinfo is None:
    raise SystemExit("finishedAt timezone icermiyor")
parsed = parsed.astimezone(dt.timezone.utc)
epoch_us = int(parsed.timestamp()) * 1_000_000 + parsed.microsecond
normalized = parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")
print(f"{normalized}|{epoch_us}")
PY
)" || fail "Workload run bitis zamani final JSON'dan okunamadi"
IFS='|' read -r run_finished_at run_finished_epoch_us <<<"$run_end_state"
[[ "$run_finished_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$ \
   && "$run_finished_epoch_us" =~ ^[0-9]+$ ]] \
  || fail "Workload run bitis zamani guvenli formata donusturulemedi"

# Baseline workload bittikten hemen sonra alinir. Boylece run sirasinda zaten
# ilerlemis bir scheduled snapshot FORCE_SNAPSHOT kabulunu yanlislikla geciremez.
snapshot_before_force="$(
  docker compose exec -T repository-db \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
      --dbname powa_repository --tuples-only --no-align \
      --command "SELECT coalesce((extract(epoch FROM snapts) * 1000000)::bigint,0) FROM \"PoWA\".powa_snapshot_metas WHERE srvid=${server_id}"
)"
[[ "$snapshot_before_force" =~ ^[0-9]+$ ]] \
  || fail "Workload sonu snapshot baseline zamani okunamadi"

# Collector LISTEN durumunda olsa bile tek NOTIFY kaybolabilir. Birden fazla
# istek gonderip snapshot'in hem workload-sonu baseline'ini hem de final JSON
# run_end zamanini kesin olarak gecmesini bekliyoruz.
snapshot_after_us="$snapshot_before_force"
snapshot_after_at=""
for ((attempt = 1; attempt <= 20; attempt++)); do
  docker compose exec -T repository-db \
    psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
      --dbname powa_repository \
      --command "NOTIFY powa_collector, 'FORCE_SNAPSHOT - ${server_id}'" >/dev/null
  sleep 3
  snapshot_after_state="$(
    docker compose exec -T repository-db \
      psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
        --dbname powa_repository --tuples-only --no-align --field-separator='|' \
        --command "SELECT coalesce((extract(epoch FROM snapts) * 1000000)::bigint,0), coalesce(to_char(snapts AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'),'') FROM \"PoWA\".powa_snapshot_metas WHERE srvid=${server_id}"
  )"
  IFS='|' read -r snapshot_after_us snapshot_after_at <<<"$snapshot_after_state"
  if [[ "$snapshot_after_us" =~ ^[0-9]+$ ]] \
     && (( snapshot_after_us > snapshot_before_force \
           && snapshot_after_us >= run_finished_epoch_us )); then
    break
  fi
done
if ! [[ "$snapshot_after_us" =~ ^[0-9]+$ ]] \
   || ! (( snapshot_after_us > snapshot_before_force \
           && snapshot_after_us >= run_finished_epoch_us )); then
  fail "FORCE sonrasi PoWA snapshot workload-sonu baseline/run_end zamanini gecmedi"
fi
pass "PoWA snapshot workload sonrasina ilerledi: ${snapshot_after_at}"

if ! bash scripts/verify-realistic-workload.sh "$report_file" 2>&1 \
  | tee -a "$report_file"; then
  fail "Realistic workload DB/telemetri kabul kapisi basarisiz"
fi

# API latency acceptance yuk durduktan sonra calisir; bu bir post-load saglik
# kapisidir, yuk altindaki dashboard latency benchmark'i degildir.
if [[ "${REALISTIC_VERIFY_RUNTIME:-false}" == "true" ]]; then
  clone_id="$(
    docker compose --profile real-validation ps --quiet --status running clone-db
  )"
  clone_evaluator_id="$(
    docker compose --profile real-validation ps --quiet --status running clone-evaluator
  )"
  [[ -n "$clone_id" && -n "$clone_evaluator_id" ]] \
    || fail "REALISTIC_VERIFY_RUNTIME=true ancak clone servisleri calismiyor"
  # 2.7 mevcut normal/stress source seed'ini kopyalamaz. Gercek DDL ve
  # EXPLAIN ANALYZE, kucuk deterministik disposable clone fixture'inda calisir.
  if ! bash scripts/verify-real-validation.sh 2>&1 | tee -a "$report_file"; then
    fail "Disposable clone gercek-index kabul kapisi basarisiz"
  fi
fi

pass "Bastan sona realistic load kabul akisi tamamlandi"
