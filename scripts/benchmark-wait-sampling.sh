#!/usr/bin/env bash
set -Eeuo pipefail

runs="${1:-3}"
duration="${2:-5}"
clients="${3:-4}"
jobs="${4:-2}"
scale="${5:-10}"

if ! [[ "$runs" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ \
    && "$clients" =~ ^[0-9]+$ && "$jobs" =~ ^[0-9]+$ \
    && "$scale" =~ ^[0-9]+$ ]] \
  || ((runs < 3 || runs > 11 || duration < 3 || duration > 60 \
       || clients < 1 || clients > 64 || jobs < 1 || jobs > clients \
       || scale < 1 || scale > 100)); then
  printf 'Kullanim: %s [runs=3..11] [seconds=3..60] [clients=1..64] [jobs=1..clients] [scale=1..100]\n' "$0" >&2
  exit 2
fi

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker bulunamadi"
docker compose version >/dev/null 2>&1 || fail "docker compose kullanilamiyor"
docker info >/dev/null 2>&1 || fail "Docker daemon calismiyor"

image="$(docker compose config --images | awk '/powa-postgres/ { print; exit }')"
[[ -n "$image" ]] || fail "Compose kaynak PostgreSQL image'i bulunamadi"
docker image inspect "$image" >/dev/null 2>&1 \
  || fail "Image yerelde yok: ${image}. Once docker compose build source-db calistirin."

docker run --rm --entrypoint sh "$image" -c \
  'test -f /usr/lib/postgresql/18/lib/pg_wait_sampling.so && command -v pgbench >/dev/null' \
  || fail "Image pg_wait_sampling veya pgbench icermiyor"

suffix="$$-$(date +%s)"
baseline_name="advisor-waits-baseline-${suffix}"
waits_name="advisor-waits-enabled-${suffix}"
[[ "$baseline_name" =~ ^advisor-waits-baseline-[0-9]+-[0-9]+$ \
   && "$waits_name" =~ ^advisor-waits-enabled-[0-9]+-[0-9]+$ ]] \
  || fail "Gecici container adlari dogrulanamadi"

cleanup() {
  docker rm -f "$baseline_name" "$waits_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

common_preload="pg_stat_statements,pg_qualstats,pg_stat_kcache"
common_args=(
  -c "compute_query_id=on"
  -c "track_io_timing=on"
  -c "pg_stat_kcache.track=top"
  -c "pg_stat_kcache.track_planning=off"
  -c "pg_qualstats.track_constants=off"
  -c "pg_qualstats.track_pg_catalog=off"
  -c "pg_qualstats.resolve_oids=off"
  -c "pg_qualstats.sample_rate=0.1"
)

docker run -d --name "$baseline_name" --shm-size=256m \
  -e POSTGRES_PASSWORD=advisor_wait_benchmark \
  "$image" postgres \
  -c "shared_preload_libraries=${common_preload}" \
  "${common_args[@]}" >/dev/null

docker run -d --name "$waits_name" --shm-size=256m \
  -e POSTGRES_PASSWORD=advisor_wait_benchmark \
  "$image" postgres \
  -c "shared_preload_libraries=${common_preload},pg_wait_sampling" \
  "${common_args[@]}" \
  -c "pg_wait_sampling.profile_period=10" \
  -c "pg_wait_sampling.profile_pid=off" \
  -c "pg_wait_sampling.profile_queries=top" \
  -c "pg_wait_sampling.sample_cpu=off" >/dev/null

wait_ready() {
  local container="$1"
  local attempt
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if docker exec "$container" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs "$container" >&2 || true
  return 1
}

wait_ready "$baseline_name" || fail "Baseline PostgreSQL hazir olmadi"
wait_ready "$waits_name" || fail "Wait-enabled PostgreSQL hazir olmadi"

for container in "$baseline_name" "$waits_name"; do
  docker exec "$container" pgbench -q -i -s "$scale" -U postgres postgres
  docker exec "$container" pgbench -q -n -T 3 -c "$clients" -j "$jobs" \
    -U postgres postgres >/dev/null
done
pass "Iki izole pgbench veritabani hazir ve isitildi"

measure_tps() {
  local container="$1"
  local output
  local value
  output="$(docker exec "$container" pgbench -n -T "$duration" \
    -c "$clients" -j "$jobs" -U postgres postgres)" \
    || fail "pgbench olcumu basarisiz: ${container}"
  value="$(awk '/^tps =/ && /without initial connection time/ {print $3}' <<< "$output" | tail -n 1)"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "pgbench TPS sonucu okunamadi: ${container}"
  printf '%s\n' "$value"
}

baseline_results=()
waits_results=()
for run_no in $(seq 1 "$runs"); do
  if ((run_no % 2 == 1)); then
    baseline_results+=("$(measure_tps "$baseline_name")")
    waits_results+=("$(measure_tps "$waits_name")")
  else
    waits_results+=("$(measure_tps "$waits_name")")
    baseline_results+=("$(measure_tps "$baseline_name")")
  fi
  baseline_last="${baseline_results[$((${#baseline_results[@]} - 1))]}"
  waits_last="${waits_results[$((${#waits_results[@]} - 1))]}"
  printf '[RUN %s/%s] baseline=%s TPS, waits=%s TPS\n' \
    "$run_no" "$runs" "$baseline_last" "$waits_last"
done

median() {
  sort -n | awk '
    { values[NR] = $1 }
    END {
      if (NR % 2) print values[(NR + 1) / 2]
      else printf "%.6f\n", (values[NR / 2] + values[NR / 2 + 1]) / 2
    }
  '
}

baseline_median="$(printf '%s\n' "${baseline_results[@]}" | median)"
waits_median="$(printf '%s\n' "${waits_results[@]}" | median)"
result="$(awk -v baseline="$baseline_median" -v waits="$waits_median" 'BEGIN {
  delta = 100 * (waits - baseline) / baseline
  cost = 100 * (baseline - waits) / baseline
  printf "baseline_median_tps=%.2f|waits_median_tps=%.2f|tps_delta_percent=%.2f|throughput_cost_percent=%.2f", baseline, waits, delta, cost
}')"

printf '\nruns=%s|seconds=%s|clients=%s|jobs=%s|scale=%s|%s\n' \
  "$runs" "$duration" "$clients" "$jobs" "$scale" "$result"
printf '%s\n' \
  "Not: Bu sonuc iki disposable container arasindaki kisa pgbench karsilastirmasidir; uretim garantisi degildir." \
  "Container'lar ve anonim verileri cikista otomatik silinir; calisan Compose stack'i ve ayarlari degismez."
