#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "${script_dir}/.." && pwd -P)"
cd "$project_dir"

if command -v python3 >/dev/null 2>&1; then
  python_bin=python3
elif command -v python >/dev/null 2>&1; then
  python_bin=python
else
  fail "Runtime yanitini dogrulamak icin Python 3 gerekli"
fi

docker compose --profile real-validation config --quiet

required_services=(source-db repository-db api evaluator clone-db clone-evaluator)
for service in "${required_services[@]}"; do
  service_id="$(
    docker compose --profile real-validation ps --quiet --status running "$service"
  )"
  [[ -n "$service_id" ]] || fail "${service} calismiyor"
done
pass "Default stack ve real-validation servisleri calisiyor"

source_alias="${RUNTIME_VALIDATION_SOURCE_ALIAS:-}"
if [[ -z "$source_alias" ]]; then
  source_alias="$(
    docker compose --profile real-validation exec -T repository-db \
      printenv JOIN_SOURCE_ALIAS
  )"
fi
[[ -n "$source_alias" ]] || fail "JOIN_SOURCE_ALIAS belirlenemedi"

candidate_identity="$(
  docker compose --profile real-validation exec -T repository-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username postgres --port 5433 --dbname powa_repository \
      --tuples-only --no-align --field-separator='|' \
      --set=source_alias="$source_alias" <<'SQL'
SELECT
    candidate.candidate_id,
    candidate.server_id,
    candidate.database_id::bigint,
    candidate.query_id,
    candidate.relation_id::bigint,
    candidate.schema_name,
    candidate.table_name,
    candidate.key_column_names[1],
    candidate.key_column_names[2]
FROM advisor.composite_index_candidates(interval '30 days') AS candidate
JOIN "PoWA".powa_servers AS server
  ON server.id = candidate.server_id
JOIN "PoWA".powa_databases AS database
  ON database.srvid = candidate.server_id
 AND database.oid = candidate.database_id
JOIN LATERAL (
    SELECT true AS exact_scalar_query
    FROM "PoWA".powa_statements AS statement
    WHERE statement.srvid = candidate.server_id
      AND statement.dbid = candidate.database_id
      AND statement.queryid = candidate.query_id
    GROUP BY statement.srvid, statement.dbid, statement.queryid
    HAVING bool_and(
        regexp_count(statement.query, '\$[0-9]+') = 1
        AND regexp_replace(btrim(statement.query), '[[:space:]]+', ' ', 'g') =
            'SELECT count(*) FROM public.customers AS c JOIN public.orders AS o ON o.customer_id = c.id WHERE o.status = $1'
    )
) AS replay_query ON true
WHERE server.alias = :'source_alias'
  AND database.datname = 'appdb'
  AND candidate.schema_name = 'public'
  AND candidate.table_name = 'orders'
  AND candidate.key_column_names = ARRAY['status', 'customer_id']::text[]
ORDER BY candidate.observed_to DESC,
         candidate.sample_count DESC,
         candidate.join_occurrences + candidate.filter_occurrences DESC,
         candidate.candidate_id
LIMIT 1;
SQL
)"

IFS='|' read -r \
  candidate_id server_id database_id query_id relation_id \
  schema_name table_name first_column second_column candidate_extra \
  <<<"$candidate_identity"
second_column="${second_column%$'\r'}"

[[ "$candidate_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ \
   && "$server_id" =~ ^[0-9]+$ \
   && "$database_id" =~ ^[0-9]+$ \
   && "$query_id" =~ ^-?[0-9]+$ \
   && "$relation_id" =~ ^[0-9]+$ \
   && "$schema_name" == "public" \
   && "$table_name" == "orders" \
   && "$first_column" == "status" \
   && "$second_column" == "customer_id" \
   && -z "${candidate_extra:-}" ]] \
  || fail "Tek scalar bind'li equality composite adayi bulunamadi"
pass "Persisted (status, customer_id) equality adayi bulundu: ${candidate_id}"

target_index_state() {
  local service="$1"
  local database_user="$2"
  local database_name="$3"
  local database_port="$4"

  docker compose --profile real-validation exec -T "$service" \
    psql -X --set=ON_ERROR_STOP=1 \
      --username "$database_user" --port "$database_port" --dbname "$database_name" \
      --tuples-only --no-align --field-separator='|' <<'SQL'
WITH target AS (
    SELECT
        relation.oid AS relation_id,
        ARRAY[
            (SELECT attribute.attnum
               FROM pg_attribute AS attribute
              WHERE attribute.attrelid = relation.oid
                AND attribute.attname = 'status'
                AND attribute.attnum > 0
                AND NOT attribute.attisdropped),
            (SELECT attribute.attnum
               FROM pg_attribute AS attribute
              WHERE attribute.attrelid = relation.oid
                AND attribute.attname = 'customer_id'
                AND attribute.attnum > 0
                AND NOT attribute.attisdropped)
        ]::smallint[] AS key_attnums
    FROM pg_class AS relation
    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'orders'
      AND relation.relkind IN ('r', 'p')
), exact_index AS (
    SELECT count(*)::bigint AS index_count
    FROM target
    JOIN pg_index AS index_record ON index_record.indrelid = target.relation_id
    JOIN pg_class AS index_class ON index_class.oid = index_record.indexrelid
    JOIN pg_am AS access_method ON access_method.oid = index_class.relam
    WHERE access_method.amname = 'btree'
      AND index_record.indisvalid
      AND index_record.indisready
      AND index_record.indpred IS NULL
      AND index_record.indexprs IS NULL
      AND index_record.indnkeyatts >= 2
      AND ARRAY(
          SELECT key.attnum
          FROM unnest(index_record.indkey::smallint[]) WITH ORDINALITY
               AS key(attnum, ordinality)
          WHERE key.ordinality <= 2
          ORDER BY key.ordinality
      )::smallint[] = target.key_attnums
), inventory AS (
    SELECT md5(coalesce(
        string_agg(
            pg_get_indexdef(index_record.indexrelid),
            E'\n' ORDER BY pg_get_indexdef(index_record.indexrelid)
        ),
        ''
    )) AS fingerprint
    FROM target
    LEFT JOIN pg_index AS index_record
      ON index_record.indrelid = target.relation_id
)
SELECT target.relation_id::bigint, exact_index.index_count, inventory.fingerprint
FROM target
CROSS JOIN exact_index
CROSS JOIN inventory;
SQL
}

repository_job_count() {
  docker compose --profile real-validation exec -T repository-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username postgres --port 5433 --dbname powa_repository \
      --tuples-only --no-align <<'SQL'
SELECT count(*)
FROM pg_database
WHERE datname LIKE 'advisor_base_%'
   OR datname LIKE 'advisor_cand_%';
SQL
}

clone_cluster_state() {
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname postgres \
      --tuples-only --no-align --field-separator='|' <<'SQL'
SELECT
    lower(coalesce(current_setting('advisor.validation_clone', true), '')),
    coalesce((SELECT datistemplate FROM pg_database WHERE datname = 'appdb'), false),
    (SELECT count(*)
       FROM pg_database
      WHERE datname LIKE 'advisor_base_%'
         OR datname LIKE 'advisor_cand_%');
SQL
}

clone_manifest_state() {
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname appdb \
      --tuples-only --no-align --field-separator='|' <<'SQL'
SELECT
    count(*) = 1,
    coalesce(bool_and(NOT source_ddl_executed), false)
FROM advisor_clone_meta.template_manifest
WHERE singleton;
SQL
}

source_index_before="$(target_index_state source-db postgres appdb 5432)"
IFS='|' read -r source_relation_before source_candidate_indexes_before source_fingerprint_before \
  <<<"$source_index_before"
[[ "$source_relation_before" == "$relation_id" \
   && "$source_candidate_indexes_before" == "0" \
   && "$source_fingerprint_before" =~ ^[0-9a-f]{32}$ ]] \
  || fail "Kaynak index preflight'i beklenmiyor: ${source_index_before:-bos}"

repository_jobs_before="$(repository_job_count)"
[[ "$repository_jobs_before" == "0" ]] \
  || fail "Repository cluster'da eski disposable job database kalintisi var: ${repository_jobs_before}"

clone_cluster_before="$(clone_cluster_state)"
[[ "$clone_cluster_before" == "on|t|0" ]] \
  || fail "Clone cluster/template preflight'i beklenmiyor: ${clone_cluster_before:-bos}"

clone_manifest_before="$(clone_manifest_state)"
[[ "$clone_manifest_before" == "t|t" ]] \
  || fail "Clone template manifest'i source DDL'siz degil: ${clone_manifest_before:-bos}"

clone_index_before="$(target_index_state clone-db clone_admin appdb 5432)"
IFS='|' read -r clone_relation_before clone_candidate_indexes_before clone_fingerprint_before \
  <<<"$clone_index_before"
[[ "$clone_relation_before" =~ ^[0-9]+$ \
   && "$clone_candidate_indexes_before" == "0" \
   && "$clone_fingerprint_before" =~ ^[0-9a-f]{32}$ ]] \
  || fail "Clone template index preflight'i beklenmiyor: ${clone_index_before:-bos}"
pass "Kaynak, repository ve clone template DDL/kalinti preflight'i temiz"

fixture_value="${RUNTIME_VALIDATION_BIND_VALUE:-paid}"
export ADVISOR_RUNTIME_ACCEPTANCE_SCALAR="$fixture_value"
fixture_json="$("$python_bin" - <<'PY'
import json
import os

value = os.environ["ADVISOR_RUNTIME_ACCEPTANCE_SCALAR"]
if len(value) > 2048:
    raise SystemExit("runtime validation scalar is too long")
print(json.dumps([value], ensure_ascii=False, separators=(",", ":")))
PY
)" || fail "Scalar replay fixture JSON'a cevrilemedi"
unset ADVISOR_RUNTIME_ACCEPTANCE_SCALAR fixture_value

printf '%s\n' "$fixture_json" | bash scripts/register-runtime-replay-fixture.sh \
  --candidate-id "$candidate_id" \
  --values-file - \
  --approved-by "${RUNTIME_VALIDATION_APPROVED_BY:-verify-real-validation.sh}" \
  --ticket "${RUNTIME_VALIDATION_TICKET:-local-real-validation-${candidate_id}}" \
  --value-class SYNTHETIC \
  --note "Disposable clone real-validation acceptance fixture"
unset fixture_json
pass "Tek sentetik scalar replay fixture operator kayit yoluyla hazirlandi"

response_file="$(mktemp "${TMPDIR:-/tmp}/advisor-real-validation.XXXXXX")"
cleanup_response() {
  [[ -n "${response_file:-}" ]] && rm -f -- "$response_file"
}
trap cleanup_response EXIT

endpoint_call_ok=false
if docker compose --profile real-validation exec -T \
  -e ACCEPTANCE_QUERY_ID="$query_id" \
  -e ACCEPTANCE_SERVER_ID="$server_id" \
  -e ACCEPTANCE_DATABASE_ID="$database_id" \
  -e ACCEPTANCE_CANDIDATE_ID="$candidate_id" \
  api python - >"$response_file" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ.get("RUNTIME_ADMIN_TOKEN", "")
if len(token) < 16:
    raise SystemExit("api container RUNTIME_ADMIN_TOKEN is not configured")

query_id = int(os.environ["ACCEPTANCE_QUERY_ID"])
payload = json.dumps(
    {
        "serverId": int(os.environ["ACCEPTANCE_SERVER_ID"]),
        "databaseId": int(os.environ["ACCEPTANCE_DATABASE_ID"]),
        "candidateId": os.environ["ACCEPTANCE_CANDIDATE_ID"],
    },
    separators=(",", ":"),
).encode("utf-8")
request = urllib.request.Request(
    f"http://127.0.0.1:8000/api/v1/queries/{query_id}/runtime-index-validations?window=30d",
    data=payload,
    headers={
        "Content-Type": "application/json",
        "X-Advisor-Role": "admin",
        "X-Advisor-Admin-Token": token,
    },
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=180) as response:
        body = response.read()
        if response.status != 200:
            raise SystemExit(f"runtime endpoint returned HTTP {response.status}")
except urllib.error.HTTPError as error:
    detail = error.read().decode("utf-8", errors="replace")[:1000]
    print(f"runtime endpoint HTTP {error.code}: {detail}", file=sys.stderr)
    raise SystemExit(1) from error
except urllib.error.URLError as error:
    print(f"runtime endpoint connection failed: {error.reason}", file=sys.stderr)
    raise SystemExit(1) from error

sys.stdout.buffer.write(body)
PY
then
  endpoint_call_ok=true
fi

# Audit the databases before interpreting the response so cleanup and source
# isolation are checked even when the endpoint returns an unsuccessful result.
source_index_after="$(target_index_state source-db postgres appdb 5432)"
repository_jobs_after="$(repository_job_count)"
clone_cluster_after="$(clone_cluster_state)"
clone_manifest_after="$(clone_manifest_state)"
clone_index_after="$(target_index_state clone-db clone_admin appdb 5432)"

[[ "$source_index_after" == "$source_index_before" ]] \
  || fail "Runtime cagrisi kaynak index katalogunu degistirdi"
[[ "$repository_jobs_after" == "0" ]] \
  || fail "Repository cluster'da disposable job database kaldi: ${repository_jobs_after}"
[[ "$clone_cluster_after" == "$clone_cluster_before" ]] \
  || fail "Clone cluster'da disposable database veya template durum kalintisi var: ${clone_cluster_after}"
[[ "$clone_manifest_after" == "$clone_manifest_before" ]] \
  || fail "Clone template manifest'i runtime cagrisi sirasinda degisti"
[[ "$clone_index_after" == "$clone_index_before" ]] \
  || fail "Clone template'te candidate index veya baska DDL kalintisi var"
pass "Kaynak DDL'siz kaldi; repository ve clone template'te disposable kalinti yok"

[[ "$endpoint_call_ok" == true ]] || fail "Admin runtime endpoint cagrisi basarisiz"

runtime_summary="$("$python_bin" - "$response_file" "$candidate_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)

validation = result.get("validation")
checks = {
    "candidateId": str(result.get("candidateId", "")).lower() == sys.argv[2].lower(),
    "status=RUNTIME_VALIDATED": result.get("status") == "RUNTIME_VALIDATED",
    "candidateIndexUsed=true": isinstance(validation, dict)
    and validation.get("candidateIndexUsed") is True,
    "ddlTarget=DISPOSABLE_CLONE": result.get("ddlTarget") == "DISPOSABLE_CLONE",
    "sourceDdlExecuted=false": result.get("sourceDdlExecuted") is False,
    "cloneDdlExecuted=true": result.get("cloneDdlExecuted") is True,
    "cloneDestroyed=true": result.get("cloneDestroyed") is True,
}
failed = [name for name, accepted in checks.items() if not accepted]
if failed:
    raise SystemExit("runtime acceptance failed: " + ", ".join(failed))

improvement = validation.get("executionImprovementPercent")
print(f"status=RUNTIME_VALIDATED, indexUsed=true, improvement={improvement}%")
PY
)" || fail "Runtime yaniti kabul sozlesmesini karsilamadi"

pass "${runtime_summary}"
pass "Gercek index yalniz disposable candidate clone'da kullanildi ve tamamen temizlendi"
