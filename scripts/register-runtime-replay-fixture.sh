#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Kullanim:
  bash scripts/register-runtime-replay-fixture.sh \
    --candidate-id UUID --values-file FILE|- --approved-by OPERATOR --ticket TICKET \
    [--value-class SYNTHETIC|ANONYMIZED] [--expires-at ISO-8601] [--note TEXT]

Bind degerleri JSON dizisi olmali (ornegin ["paid"]). Uretim bind degerlerini
toplamayin; yalniz sentetik veya kurum prosedurune gore anonimlestirilmis test
degerleri kullanin. FILE yerine - verilirse JSON tek satir olarak stdin'den okunur.
USAGE
}

candidate_id=""
values_file=""
approved_by=""
approval_ticket=""
value_class="SYNTHETIC"
expires_at=""
note=""

while (($#)); do
  case "$1" in
    --candidate-id) candidate_id="${2:?--candidate-id degeri eksik}"; shift 2 ;;
    --values-file) values_file="${2:?--values-file degeri eksik}"; shift 2 ;;
    --approved-by) approved_by="${2:?--approved-by degeri eksik}"; shift 2 ;;
    --ticket) approval_ticket="${2:?--ticket degeri eksik}"; shift 2 ;;
    --value-class) value_class="${2:?--value-class degeri eksik}"; shift 2 ;;
    --expires-at) expires_at="${2:?--expires-at degeri eksik}"; shift 2 ;;
    --note) note="${2:?--note degeri eksik}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Bilinmeyen arguman: $1" ;;
  esac
done

[[ "$candidate_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || fail "Gecerli --candidate-id UUID gerekli"
[[ -n "$values_file" ]] || fail "--values-file gerekli"
[[ -n "$approved_by" && ${#approved_by} -le 200 ]] || fail "--approved-by 1-200 karakter olmali"
[[ -n "$approval_ticket" && ${#approval_ticket} -le 200 ]] || fail "--ticket 1-200 karakter olmali"
[[ "$value_class" == "SYNTHETIC" || "$value_class" == "ANONYMIZED" ]] \
  || fail "--value-class SYNTHETIC veya ANONYMIZED olmali"
[[ ${#note} -le 1000 ]] || fail "--note en fazla 1000 karakter olmali"

if [[ "$values_file" == "-" ]]; then
  IFS= read -r bind_values || fail "stdin'den tek satir JSON okunamadi"
else
  [[ -f "$values_file" && -r "$values_file" ]] || fail "Values dosyasi okunamiyor: ${values_file}"
  bind_values="$(<"$values_file")"
fi

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fail "JSON dogrulamasi icin Python 3 gerekli"
fi

export ADVISOR_REPLAY_VALUES_TO_VALIDATE="$bind_values"
bind_values="$($python_bin - <<'PY'
import json
import math
import os

values = json.loads(os.environ["ADVISOR_REPLAY_VALUES_TO_VALIDATE"])
if not isinstance(values, list) or len(values) > 16:
    raise SystemExit("bind values must be a JSON array with at most 16 items")
for value in values:
    if value is not None and type(value) not in (str, int, float, bool):
        raise SystemExit("bind values must contain JSON scalars only")
    if isinstance(value, str) and len(value) > 2048:
        raise SystemExit("string bind value is too long")
    if isinstance(value, float) and not math.isfinite(value):
        raise SystemExit("numeric bind value must be finite")
encoded = json.dumps(values, ensure_ascii=False, separators=(",", ":"))
if len(encoded.encode("utf-8")) > 8192:
    raise SystemExit("bind value payload is larger than 8KiB")
print(encoded)
PY
)" || fail "Bind JSON guvenlik dogrulamasi basarisiz"
unset ADVISOR_REPLAY_VALUES_TO_VALIDATE

docker compose config --quiet
docker compose ps --services --status running | grep -qx repository-db \
  || fail "repository-db calismiyor"
bash scripts/migrate-repository.sh >/dev/null

docker compose exec -T \
  -e REPLAY_CANDIDATE_ID="$candidate_id" \
  -e REPLAY_BIND_VALUES_JSON="$bind_values" \
  -e REPLAY_VALUE_CLASS="$value_class" \
  -e REPLAY_APPROVED_BY="$approved_by" \
  -e REPLAY_APPROVAL_TICKET="$approval_ticket" \
  -e REPLAY_EXPIRES_AT="$expires_at" \
  -e REPLAY_NOTE="$note" \
  repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository >/dev/null <<'SQL'
\getenv candidate_id REPLAY_CANDIDATE_ID
\getenv bind_values REPLAY_BIND_VALUES_JSON
\getenv value_class REPLAY_VALUE_CLASS
\getenv approved_by REPLAY_APPROVED_BY
\getenv approval_ticket REPLAY_APPROVAL_TICKET
\getenv expires_at REPLAY_EXPIRES_AT
\getenv fixture_note REPLAY_NOTE

SELECT advisor_ingest.upsert_runtime_replay_fixture(
    :'candidate_id'::uuid,
    statement.query,
    :'bind_values'::jsonb,
    :'value_class',
    :'approved_by',
    :'approval_ticket',
    coalesce(nullif(:'expires_at', '')::timestamptz, clock_timestamp() + interval '7 days'),
    nullif(:'fixture_note', '')
)
FROM advisor.index_candidates AS candidate
JOIN "PoWA".powa_statements AS statement
  ON statement.srvid = candidate.server_id
 AND statement.dbid = candidate.database_id
 AND statement.queryid = candidate.query_id
WHERE candidate.candidate_id = :'candidate_id'::uuid
ORDER BY statement.userid
LIMIT 1;
SQL

fixture_ok="$(docker compose exec -T repository-db psql -X --set=ON_ERROR_STOP=1 \
  --username postgres --port 5433 --dbname powa_repository --tuples-only --no-align \
  --set=candidate_id="$candidate_id" <<'SQL'
SELECT status.available
FROM advisor.index_candidates AS candidate
JOIN "PoWA".powa_statements AS statement
  ON statement.srvid = candidate.server_id
 AND statement.dbid = candidate.database_id
 AND statement.queryid = candidate.query_id
CROSS JOIN LATERAL advisor.runtime_replay_fixture_status(
    ARRAY[candidate.candidate_id], candidate.server_id, candidate.database_id,
    candidate.query_id, statement.query
) AS status
WHERE candidate.candidate_id = :'candidate_id'::uuid
ORDER BY statement.userid
LIMIT 1;
SQL
)"
[[ "$fixture_ok" == "t" ]] || fail "Replay fixture exact-query lookup ile dogrulanamadi"

unset bind_values
pass "Operator onayli runtime replay fixture kaydedildi; bind degerleri loglanmadi"
