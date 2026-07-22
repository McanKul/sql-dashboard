#!/usr/bin/env bash
set -Eeuo pipefail

iterations="${1:-20}"

if ! [[ "$iterations" =~ ^[0-9]+$ ]] || (( iterations < 1 || iterations > 1000 )); then
  echo "Kullanim: $0 [1-1000 arasinda iteration]" >&2
  exit 2
fi

docker compose exec -T source-db \
  psql -U postgres -d appdb -Atqc \
  "SELECT run_advisor_test_workload(${iterations});"

echo "Test yuku tamamlandi. Collector frekansi 5 saniye; iki snapshot icin yaklasik 10 saniye bekleyin."

