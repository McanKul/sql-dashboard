#!/usr/bin/env bash
set -Eeuo pipefail

runs="${1:-7}"
iterations="${2:-50}"

if ! [[ "$runs" =~ ^[0-9]+$ && "$iterations" =~ ^[0-9]+$ ]] \
  || ((runs < 3 || runs > 31 || iterations < 1 || iterations > 1000)); then
  printf 'Kullanim: %s [runs=3..31] [iterations=1..1000]\n' "$0" >&2
  exit 2
fi

docker compose ps --services --status running | grep -qx source-db \
  || { echo "source-db calismiyor" >&2; exit 1; }

docker compose exec -T source-db psql -X --set=ON_ERROR_STOP=1 \
  -U postgres -d appdb -AtF '|' \
  --set=runs="$runs" --set=iterations="$iterations" <<'SQL'
CREATE TEMP TABLE kcache_benchmark(mode text, duration_ms double precision);
CREATE TEMP TABLE kcache_benchmark_config AS
SELECT :runs::integer AS runs, :iterations::integer AS iterations;

DO $benchmark$
DECLARE
    run_no integer;
    run_count integer;
    iteration_count integer;
    started_at timestamptz;
BEGIN
    SELECT runs, iterations INTO run_count, iteration_count
    FROM kcache_benchmark_config;

    FOR run_no IN 1..run_count LOOP
        PERFORM set_config('pg_stat_kcache.track', 'none', false);
        started_at := clock_timestamp();
        PERFORM run_advisor_test_workload(iteration_count);
        INSERT INTO kcache_benchmark VALUES
            ('off', extract(epoch FROM clock_timestamp() - started_at) * 1000);

        PERFORM set_config('pg_stat_kcache.track', 'top', false);
        started_at := clock_timestamp();
        PERFORM run_advisor_test_workload(iteration_count);
        INSERT INTO kcache_benchmark VALUES
            ('on', extract(epoch FROM clock_timestamp() - started_at) * 1000);
    END LOOP;
END
$benchmark$;

WITH medians AS (
    SELECT mode, percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) AS median_ms
    FROM kcache_benchmark
    GROUP BY mode
), values AS (
    SELECT
        max(median_ms) FILTER (WHERE mode='off') AS off_ms,
        max(median_ms) FILTER (WHERE mode='on') AS on_ms
    FROM medians
)
SELECT 'runs=' || :runs ||
       '|iterations=' || :iterations ||
       '|off_median_ms=' || round(off_ms::numeric, 2) ||
       '|on_median_ms=' || round(on_ms::numeric, 2) ||
       '|overhead_percent=' || round((100 * (on_ms - off_ms) / NULLIF(off_ms, 0))::numeric, 2)
FROM values;
SQL

echo "Not: Bu kisa ve sirali mikro-olcum bir uretim overhead garantisi degildir; ayni donanimda trend karsilastirmasi icindir."
