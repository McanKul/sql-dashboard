#!/usr/bin/env bash
set -Eeuo pipefail

alias_name="${1:-${SOURCE_ALIAS:-}}"
api_url="${API_URL:-http://localhost:8000}"

[[ -n "$alias_name" ]] || {
  echo "Kullanim: scripts/verify-source.sh <alias>" >&2
  exit 2
}
[[ "$alias_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo "Gecersiz alias: ${alias_name}" >&2
  exit 2
}

pass() { echo "[OK] $1"; }
fail() { echo "[HATA] $1" >&2; exit 1; }

repo_sql='SELECT s.id, s.hostname, s.port, s.dbname, s.frequency,
                 s.password IS NULL,
                 m.snapts > '\''-infinity'\''::timestamptz,
                 cardinality(coalesce(m.errors, ARRAY[]::text[]))
            FROM "PoWA".powa_servers AS s
            JOIN "PoWA".powa_snapshot_metas AS m ON m.srvid = s.id
           WHERE s.alias = :'\''source_alias'\'';'
row="$(printf '%s\n' "$repo_sql" | docker compose exec -T repository-db \
  psql -X --set=ON_ERROR_STOP=1 --username postgres --port 5433 \
  --dbname powa_repository --tuples-only --no-align --field-separator='|' \
  --set=source_alias="$alias_name")"

[[ -n "$row" ]] || fail "Repository'de alias bulunamadi: ${alias_name}"
IFS='|' read -r server_id hostname port database frequency password_null has_snapshot error_count <<< "$row"
[[ "$server_id" =~ ^[0-9]+$ ]] || fail "Server id gecersiz: ${server_id}"
[[ "$frequency" =~ ^[0-9]+$ ]] && ((frequency >= 5)) || fail "Kaynak aktif degil: frequency=${frequency}"
[[ "$password_null" == t ]] || fail "Kaynak parolasi repository'de saklaniyor"
[[ "$has_snapshot" == t ]] || fail "Kaynak henuz snapshot uretmedi"
[[ "$error_count" == 0 ]] || fail "Collector kaynak icin ${error_count} hata raporluyor"
pass "PoWA kaydi aktif; parola NULL ve snapshot saglikli (server id ${server_id})"

secret_path="runtime/collector/sources/${alias_name}.pgpass"
[[ -f "$secret_path" ]] || fail "Collector secret dosyasi bulunamadi: ${secret_path}"
permission="$(stat -f '%Lp' "$secret_path" 2>/dev/null || stat -c '%a' "$secret_path")"
[[ "$permission" == 600 ]] || fail "Secret dosya izni 600 degil: ${permission}"
pass "Collector credential dosyasi 0600 ve Git-disinda"

api_json="$(curl -fsS "${api_url}/api/v1/servers")" || fail "API /servers okunamadi: ${api_url}"
SOURCE_ALIAS_TO_VERIFY="$alias_name" python3 -c '
import json, os, sys
payload = json.load(sys.stdin)
alias = os.environ["SOURCE_ALIAS_TO_VERIFY"]
assert any(item.get("alias") == alias for item in payload.get("items", [])), payload
' <<< "$api_json" || fail "Kaynak API /servers yanitinda yok"
pass "Kaynak API /servers listesinde gorunuyor"

printf '\nKaynak dogrulandi: %s -> %s:%s/%s\n' "$alias_name" "$hostname" "$port" "$database"
