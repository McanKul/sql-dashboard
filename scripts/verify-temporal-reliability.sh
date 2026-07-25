#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"

bash scripts/migrate-repository.sh >/dev/null

docker compose exec -T repository-db \
  psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository \
  --file /opt/advisor/sql/tests/reset_coverage_integration.sql >/dev/null

pass "Query, pg_stat_kcache ve wait reset deltalari ile gap/coverage semantigi dogrulandi"
