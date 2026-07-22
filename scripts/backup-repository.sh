#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p backups
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="backups/powa_repository-${timestamp}.dump"

docker compose exec -T repository-db \
  pg_dump -U postgres -p 5433 -d powa_repository -Fc >"$target"

test -s "$target"
echo "Repository yedegi olusturuldu: ${target}"
