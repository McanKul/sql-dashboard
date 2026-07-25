#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

docker compose config --quiet
docker compose up -d repository-db >/dev/null

for attempt in $(seq 1 30); do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "$(docker compose ps -q repository-db)" 2>/dev/null || true)"
  [[ "$health" == healthy ]] && break
  if (( attempt == 30 )); then
    fail "repository-db 60 saniye icinde hazir olmadi (health=${health:-unknown})"
  fi
  sleep 2
done

docker compose run --rm --no-deps repository-migrate
pass "Repository migration manifesti, checksumlari ve schema_migrations kayitlari dogrulandi"
