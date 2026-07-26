#!/usr/bin/env bash
set -Eeuo pipefail

iterations="${1:-20}"

if ! [[ "$iterations" =~ ^[0-9]+$ ]] || (( iterations < 1 || iterations > 1000 )); then
  echo "Kullanim: $0 [1-1000 arasinda iteration]" >&2
  exit 2
fi

docker compose exec -T source-db \
  psql -U postgres -d appdb -Atqc \
  "SET pg_qualstats.sample_rate = 1; SELECT run_advisor_test_workload(${iterations});"

collector_frequency="$(docker compose exec -T repository-db \
  psql -X -U postgres -p 5433 -d powa_repository -Atqc \
  "SELECT frequency FROM \"PoWA\".powa_servers WHERE alias='test-source'")"
if [[ "$collector_frequency" =~ ^[0-9]+$ ]]; then
  echo "Test yuku tamamlandi. Collector frekansi ${collector_frequency} saniye; iki snapshot icin yaklasik $((collector_frequency * 2)) saniye bekleyin."
else
  echo "Test yuku tamamlandi. Collector frekansi okunamadi; Sistem Sagligi ekranindan iki snapshot olustugunu dogrulayin."
fi
