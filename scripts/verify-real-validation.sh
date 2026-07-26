#!/usr/bin/env bash
set -Eeuo pipefail

pass() { printf '[OK] %s\n' "$1"; }
fail() { printf '[HATA] %s\n' "$1" >&2; exit 1; }

policy_probe_database=""
policy_probe_cleanup_authorized=false
response_file=""
query_response_file=""

cleanup_policy_probe() {
  local target_database="${policy_probe_database:-}"
  [[ -n "$target_database" ]] || return 0
  [[ "${policy_probe_cleanup_authorized:-false}" == true ]] || return 0
  [[ "$target_database" =~ ^advisor_policy_probe_[0-9]+_[0-9]+$ ]] || return 1

  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname postgres \
      --set=probe_database="$target_database" >/dev/null 2>&1 <<'SQL'
SELECT pg_catalog.pg_terminate_backend(activity.pid)
FROM pg_catalog.pg_stat_activity AS activity
WHERE activity.datname = :'probe_database'
  AND activity.pid <> pg_catalog.pg_backend_pid();
SELECT pg_catalog.format(
    'DROP DATABASE IF EXISTS %I WITH (FORCE)',
    :'probe_database'
)
\gexec
SQL

  local remaining
  remaining="$(
    docker compose --profile real-validation exec -T clone-db \
      psql -X --set=ON_ERROR_STOP=1 \
        --username clone_admin --port 5432 --dbname postgres \
        --tuples-only --no-align --set=probe_database="$target_database" <<'SQL'
SELECT count(*)
FROM pg_catalog.pg_database
WHERE datname = :'probe_database';
SQL
  )" || return 1
  [[ "$remaining" == "0" ]] || return 1
  policy_probe_database=""
  policy_probe_cleanup_authorized=false
}

cleanup_artifacts() {
  set +e
  cleanup_policy_probe >/dev/null 2>&1
  [[ -n "${response_file:-}" ]] && rm -f -- "$response_file"
  [[ -n "${query_response_file:-}" ]] && rm -f -- "$query_response_file"
}
trap cleanup_artifacts EXIT

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

[[ "${ADVISOR_API_TOKEN:-}" =~ ^adv_pat_v1_[A-Za-z0-9_-]{43}$ ]] \
  || fail "ADVISOR_API_TOKEN secret manager'dan alinmis gecerli raw token olmali"

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
   OR datname LIKE 'advisor_cand_%'
   OR datname LIKE 'advisor_query_%';
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
         OR datname LIKE 'advisor_cand_%'
         OR datname LIKE 'advisor_query_%');
SQL
}

clone_manifest_state() {
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname appdb \
      --tuples-only --no-align --field-separator='|' \
      --set=source_alias="$source_alias" <<'SQL'
SELECT
    count(*) = 1,
    coalesce(bool_and(NOT source_ddl_executed), false),
    coalesce(bool_and(runner_policy_revision = 1), false),
    coalesce(bool_and(dangerous_routines_revoked), false),
    coalesce(bool_and(source_alias = :'source_alias'), false),
    coalesce(bool_and(source_database_name = 'appdb'), false)
FROM advisor_clone_meta.template_manifest
WHERE singleton;
SQL
}

clone_runner_policy_state() {
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname appdb \
      --tuples-only --no-align --field-separator='|' <<'SQL'
WITH runner AS (
    SELECT role.*
    FROM pg_catalog.pg_roles AS role
    WHERE role.rolname = 'clone_runner'
), role_policy AS (
    SELECT count(*) = 1
       AND coalesce(bool_and(
               role.rolcanlogin
           AND role.rolinherit
           AND NOT role.rolsuper
           AND NOT role.rolcreatedb
           AND NOT role.rolcreaterole
           AND NOT role.rolreplication
           AND NOT role.rolbypassrls
           AND role.rolconnlimit = 4
           AND role.rolvaliduntil = 'infinity'::timestamptz
           AND 'default_transaction_read_only=on' = ANY(
                   coalesce(role.rolconfig, ARRAY[]::text[])
               )
           AND 'search_path=pg_catalog, public' = ANY(
                   coalesce(role.rolconfig, ARRAY[]::text[])
               )
       ), false) AS exact
    FROM runner AS role
), membership_policy AS (
    SELECT count(*) = 1
       AND coalesce(bool_and(
               granted_role.rolname = 'pg_read_all_data'
           AND membership.inherit_option
           AND NOT membership.set_option
           AND NOT membership.admin_option
           AND NOT EXISTS (
                   SELECT 1
                   FROM pg_catalog.pg_auth_members AS inherited_membership
                   WHERE inherited_membership.member = granted_role.oid
               )
       ), false) AS exact
    FROM pg_catalog.pg_auth_members AS membership
    JOIN pg_catalog.pg_roles AS granted_role
      ON granted_role.oid = membership.roleid
    WHERE membership.member = 'clone_runner'::pg_catalog.regrole
), template_acl_policy AS (
    SELECT
        NOT pg_catalog.has_database_privilege(
            'clone_runner', pg_catalog.current_database(), 'CONNECT'
        )
        AND NOT pg_catalog.has_database_privilege(
            'clone_runner', pg_catalog.current_database(), 'TEMPORARY'
        )
        AND NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_database AS database
            CROSS JOIN LATERAL pg_catalog.aclexplode(
                coalesce(
                    database.datacl,
                    pg_catalog.acldefault('d', database.datdba)
                )
            ) AS privilege
            WHERE database.datname = pg_catalog.current_database()
              AND privilege.grantee = 0
              AND privilege.privilege_type IN ('CONNECT', 'TEMPORARY')
        )
        AND NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_namespace AS namespace
            WHERE namespace.nspname NOT LIKE 'pg_temp\_%' ESCAPE '\'
              AND namespace.nspname NOT LIKE 'pg_toast_temp\_%' ESCAPE '\'
              AND pg_catalog.has_schema_privilege(
                  'clone_runner', namespace.oid, 'CREATE'
              )
        )
        AND NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_namespace AS namespace
            CROSS JOIN LATERAL pg_catalog.aclexplode(
                coalesce(
                    namespace.nspacl,
                    pg_catalog.acldefault('n', namespace.nspowner)
                )
            ) AS privilege
            WHERE namespace.nspname NOT LIKE 'pg_temp\_%' ESCAPE '\'
              AND namespace.nspname NOT LIKE 'pg_toast_temp\_%' ESCAPE '\'
              AND privilege.grantee = 0
              AND privilege.privilege_type = 'CREATE'
        ) AS exact
), dangerous_routines AS (
    SELECT routine.oid
    FROM pg_catalog.pg_proc AS routine
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.oid = routine.pronamespace
    JOIN pg_catalog.pg_language AS language
      ON language.oid = routine.prolang
    WHERE routine.provolatile = 'v'
       OR routine.prosecdef
       OR routine.prokind = 'p'
       OR (
              namespace.nspname NOT IN ('pg_catalog', 'information_schema')
          AND namespace.nspname NOT LIKE 'pg_toast%'
          AND namespace.nspname NOT LIKE 'pg_temp\_%' ESCAPE '\'
          AND language.lanname NOT IN ('sql', 'plpgsql')
       )
), routine_policy AS (
    SELECT NOT EXISTS (
        SELECT 1
        FROM dangerous_routines AS routine
        WHERE pg_catalog.has_function_privilege(
            'clone_runner', routine.oid, 'EXECUTE'
        )
    ) AS exact
), foreign_server_policy AS (
    SELECT NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_foreign_server AS server
        WHERE pg_catalog.has_server_privilege(
            'clone_runner', server.oid, 'USAGE'
        )
    ) AS exact
)
SELECT role_policy.exact,
       membership_policy.exact,
       template_acl_policy.exact,
       routine_policy.exact,
       foreign_server_policy.exact
FROM role_policy
CROSS JOIN membership_policy
CROSS JOIN template_acl_policy
CROSS JOIN routine_policy
CROSS JOIN foreign_server_policy;
SQL
}

policy_probe_state() {
  local target_database="$1"
  [[ "$target_database" =~ ^advisor_policy_probe_[0-9]+_[0-9]+$ ]] \
    || return 1
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname "$target_database" \
      --tuples-only --no-align --field-separator='|' <<'SQL'
WITH schema_objects AS (
    SELECT relation.relkind::text || ':' || relation.relname || ':'
           || relation.relpersistence::text || ':' || owner.rolname AS identity
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS namespace
      ON namespace.oid = relation.relnamespace
    JOIN pg_catalog.pg_roles AS owner ON owner.oid = relation.relowner
    WHERE namespace.nspname = 'advisor_policy_probe'
), object_fingerprint AS (
    SELECT pg_catalog.md5(
        coalesce(pg_catalog.string_agg(identity, ',' ORDER BY identity), '')
    ) AS value
    FROM schema_objects
)
SELECT (
           SELECT count(*)
           FROM advisor_policy_probe.sentinel
       ),
       (
           SELECT pg_catalog.string_agg(
               id::text || ':' || marker,
               ',' ORDER BY id
           )
           FROM advisor_policy_probe.sentinel
       ),
       sequence.last_value,
       sequence.is_called,
       namespace_owner.rolname,
       object_fingerprint.value,
       pg_catalog.to_regclass(
           'advisor_policy_probe.forbidden_ddl'
       ) IS NULL,
       pg_catalog.to_regclass(
           'advisor_policy_probe.forbidden_select_into'
       ) IS NULL
FROM advisor_policy_probe.sentinel_sequence AS sequence
CROSS JOIN pg_catalog.pg_namespace AS namespace
JOIN pg_catalog.pg_roles AS namespace_owner
  ON namespace_owner.oid = namespace.nspowner
CROSS JOIN object_fingerprint
WHERE namespace.nspname = 'advisor_policy_probe';
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
[[ "$clone_manifest_before" == "t|t|t|t|t|t" ]] \
  || fail "Clone template manifest/policy kaniti gecersiz: ${clone_manifest_before:-bos}"

clone_runner_policy_before="$(clone_runner_policy_state)"
[[ "$clone_runner_policy_before" == "t|t|t|t|t" ]] \
  || fail "Clone runner rol/uyelik/ACL/routine/foreign-server policy'si gecersiz: ${clone_runner_policy_before:-bos}"
pass "Clone manifest revision=1 ve runner rol/ACL/routine policy'si fail-closed"

clone_index_before="$(target_index_state clone-db clone_admin appdb 5432)"
IFS='|' read -r clone_relation_before clone_candidate_indexes_before clone_fingerprint_before \
  <<<"$clone_index_before"
[[ "$clone_relation_before" =~ ^[0-9]+$ \
   && "$clone_candidate_indexes_before" == "0" \
   && "$clone_fingerprint_before" =~ ^[0-9a-f]{32}$ ]] \
  || fail "Clone template index preflight'i beklenmiyor: ${clone_index_before:-bos}"
pass "Kaynak, repository ve clone template DDL/kalinti preflight'i temiz"

policy_probe_database="advisor_policy_probe_$$_${RANDOM}"
[[ "$policy_probe_database" =~ ^advisor_policy_probe_[0-9]+_[0-9]+$ ]] \
  || fail "Disposable policy probe database adi guvenli uretilmedi"

policy_probe_exists="$(
  docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname postgres \
      --tuples-only --no-align --set=probe_database="$policy_probe_database" <<'SQL'
SELECT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_database
    WHERE datname = :'probe_database'
);
SQL
)"
[[ "$policy_probe_exists" == "f" ]] \
  || fail "Disposable policy probe database adi zaten kullanimda"
policy_probe_cleanup_authorized=true

policy_probe_created=false
for attempt in $(seq 1 10); do
  if docker compose --profile real-validation exec -T clone-db \
    psql -X --set=ON_ERROR_STOP=1 \
      --username clone_admin --port 5432 --dbname postgres \
      --set=probe_database="$policy_probe_database" >/dev/null 2>&1 <<'SQL'
SELECT pg_catalog.pg_terminate_backend(activity.pid)
FROM pg_catalog.pg_stat_activity AS activity
WHERE activity.datname = 'appdb'
  AND activity.pid <> pg_catalog.pg_backend_pid();
SELECT pg_catalog.format(
    'CREATE DATABASE %I WITH TEMPLATE %I OWNER %I',
    :'probe_database',
    'appdb',
    'clone_admin'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_database
    WHERE datname = :'probe_database'
)
\gexec
SQL
  then
    policy_probe_created=true
    break
  fi
  [[ "$attempt" == "10" ]] || sleep 1
done
[[ "$policy_probe_created" == true ]] \
  || fail "Disposable policy probe database template'ten olusturulamadi"

docker compose --profile real-validation exec -T clone-db \
  psql -X --set=ON_ERROR_STOP=1 \
    --username clone_admin --port 5432 --dbname postgres \
    --set=probe_database="$policy_probe_database" >/dev/null <<'SQL'
SELECT pg_catalog.format(
    'REVOKE ALL PRIVILEGES ON DATABASE %I FROM PUBLIC, clone_runner',
    :'probe_database'
)
\gexec
SELECT pg_catalog.format(
    'GRANT CONNECT ON DATABASE %I TO clone_runner',
    :'probe_database'
)
\gexec
SQL

docker compose --profile real-validation exec -T clone-db \
  psql -X --set=ON_ERROR_STOP=1 \
    --username clone_admin --port 5432 --dbname "$policy_probe_database" \
    >/dev/null <<'SQL'
CREATE SCHEMA advisor_policy_probe AUTHORIZATION clone_admin;
REVOKE ALL ON SCHEMA advisor_policy_probe FROM PUBLIC, clone_runner;
CREATE TABLE advisor_policy_probe.sentinel (
    id integer PRIMARY KEY,
    marker text NOT NULL
);
INSERT INTO advisor_policy_probe.sentinel(id, marker)
VALUES (1, 'original');
CREATE SEQUENCE advisor_policy_probe.sentinel_sequence START WITH 41;
REVOKE ALL ON ALL TABLES IN SCHEMA advisor_policy_probe FROM PUBLIC, clone_runner;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA advisor_policy_probe FROM PUBLIC, clone_runner;
SQL

policy_probe_before="$(policy_probe_state "$policy_probe_database")"
IFS='|' read -r \
  probe_row_count probe_rows probe_sequence_value probe_sequence_called \
  probe_schema_owner probe_object_fingerprint probe_ddl_absent \
  probe_select_into_absent probe_state_extra \
  <<<"$policy_probe_before"
[[ "$probe_row_count" == "1" \
   && "$probe_rows" == "1:original" \
   && "$probe_sequence_value" == "41" \
   && "$probe_sequence_called" == "f" \
   && "$probe_schema_owner" == "clone_admin" \
   && "$probe_object_fingerprint" =~ ^[0-9a-f]{32}$ \
   && "$probe_ddl_absent" == "t" \
   && "$probe_select_into_absent" == "t" \
   && -z "${probe_state_extra:-}" ]] \
  || fail "Disposable policy sentinel preflight'i gecersiz: ${policy_probe_before:-bos}"

docker compose --profile real-validation exec -T \
  -e POLICY_PROBE_DATABASE="$policy_probe_database" \
  clone-evaluator python - <<'PY'
import os

import psycopg


database_name = os.environ["POLICY_PROBE_DATABASE"]
if not database_name.startswith("advisor_policy_probe_"):
    raise SystemExit("invalid policy probe database")

connection_kwargs = {
    "host": os.environ.get("CLONE_DATABASE_HOST", "clone-db"),
    "port": int(os.environ.get("CLONE_DATABASE_PORT", "5432")),
    "dbname": database_name,
    "user": os.environ.get("CLONE_RUNNER_ROLE", "clone_runner"),
    "password": os.environ["CLONE_RUNNER_PASSWORD"],
    "connect_timeout": 5,
    "application_name": "postgresql-advisor-policy-probe",
}
sslmode = os.environ.get("CLONE_DATABASE_SSLMODE")
if sslmode:
    connection_kwargs["sslmode"] = sslmode


def expect_policy_rejection(cursor, label: str, statement: str) -> None:
    cursor.execute("BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED READ ONLY")
    read_only = cursor.execute(
        "SELECT current_setting('transaction_read_only')"
    ).fetchone()
    if read_only != ("on",):
        cursor.execute("ROLLBACK")
        raise SystemExit(f"{label}: transaction is not read-only")
    try:
        cursor.execute(statement, prepare=True)
    except psycopg.Error as error:
        sqlstate = error.sqlstate
        cursor.execute("ROLLBACK")
        if sqlstate not in {"25006", "42501"}:
            raise SystemExit(f"{label}: unexpected SQLSTATE {sqlstate}") from error
        return
    cursor.execute("ROLLBACK")
    raise SystemExit(f"{label}: statement unexpectedly succeeded")


with psycopg.connect(**connection_kwargs, autocommit=True) as connection:
    with connection.cursor() as cursor:
        runner_state = cursor.execute(
            "SELECT current_user, "
            "current_setting('default_transaction_read_only'), "
            "replace(current_setting('search_path'), ' ', ''), "
            "NOT has_database_privilege(current_user, current_database(), 'TEMPORARY'), "
            "NOT EXISTS ("
            "  SELECT 1 FROM pg_namespace AS namespace "
            "  WHERE left(namespace.nspname, 8) <> 'pg_temp_' "
            "    AND left(namespace.nspname, 14) <> 'pg_toast_temp_' "
            "    AND has_schema_privilege(current_user, namespace.oid, 'CREATE')"
            ")"
        ).fetchone()
        if runner_state != ("clone_runner", "on", "pg_catalog,public", True, True):
            raise SystemExit("active clone runner policy mismatch")

        sentinel = cursor.execute(
            "SELECT id, marker FROM advisor_policy_probe.sentinel ORDER BY id",
            prepare=True,
        ).fetchall()
        if sentinel != [(1, "original")]:
            raise SystemExit("clone runner cannot read the sentinel deterministically")

        expect_policy_rejection(
            cursor,
            "DML",
            "UPDATE advisor_policy_probe.sentinel "
            "SET marker = 'changed' WHERE id = 1",
        )
        expect_policy_rejection(
            cursor,
            "DDL",
            "CREATE TABLE advisor_policy_probe.forbidden_ddl(id integer)",
        )
        expect_policy_rejection(
            cursor,
            "SELECT INTO",
            "SELECT * INTO advisor_policy_probe.forbidden_select_into "
            "FROM advisor_policy_probe.sentinel",
        )
        expect_policy_rejection(
            cursor,
            "nextval",
            "SELECT pg_catalog.nextval("
            "'advisor_policy_probe.sentinel_sequence'::pg_catalog.regclass)",
        )

        try:
            cursor.execute("SELECT 1; SELECT 2", prepare=True)
        except psycopg.Error as error:
            if error.sqlstate != "42601":
                raise SystemExit(
                    f"multi-statement prepare returned SQLSTATE {error.sqlstate}"
                ) from error
        else:
            raise SystemExit("prepare=True accepted multiple statements")

        single_statement = cursor.execute("SELECT 1", prepare=True).fetchone()
        if single_statement != (1,):
            raise SystemExit("prepare=True single-statement control failed")
PY

policy_probe_after="$(policy_probe_state "$policy_probe_database")"
[[ "$policy_probe_after" == "$policy_probe_before" ]] \
  || fail "READ ONLY policy probe sentinel tablo/sequence/sema durumunu degistirdi"
cleanup_policy_probe \
  || fail "Disposable policy probe database temizlenemedi"
pass "Runner READ ONLY DML/DDL/SELECT INTO/nextval'i reddetti; prepare=True tek statement ve sentinel degismezligi dogrulandi"

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

query_response_file="$(mktemp "${TMPDIR:-/tmp}/advisor-query-explain.XXXXXX")"
query_endpoint_ok=false
if docker compose --profile real-validation exec -T \
  -e ACCEPTANCE_QUERY_ID="$query_id" \
  -e ACCEPTANCE_SERVER_ID="$server_id" \
  -e ACCEPTANCE_DATABASE_ID="$database_id" \
  -e ACCEPTANCE_BIND_VALUE="$fixture_value" \
  api python - >"$query_response_file" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

query_id = int(os.environ["ACCEPTANCE_QUERY_ID"])
payload = json.dumps(
    {
        "serverId": int(os.environ["ACCEPTANCE_SERVER_ID"]),
        "databaseId": int(os.environ["ACCEPTANCE_DATABASE_ID"]),
        "bindValues": [os.environ["ACCEPTANCE_BIND_VALUE"]],
    },
    separators=(",", ":"),
).encode("utf-8")
request = urllib.request.Request(
    f"http://127.0.0.1:8000/api/v1/queries/{query_id}/explain-analyze?window=30d",
    data=payload,
    headers={
        "Content-Type": "application/json",
        "X-Advisor-Role": "analyst",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=180) as response:
        body = response.read()
        if response.status != 200:
            raise SystemExit(f"query explain endpoint returned HTTP {response.status}")
except urllib.error.HTTPError as error:
    detail = error.read().decode("utf-8", errors="replace")[:1000]
    print(f"query explain endpoint HTTP {error.code}: {detail}", file=sys.stderr)
    raise SystemExit(1) from error
except urllib.error.URLError as error:
    print(f"query explain endpoint connection failed: {error.reason}", file=sys.stderr)
    raise SystemExit(1) from error

sys.stdout.buffer.write(body)
PY
then
  query_endpoint_ok=true
fi

source_index_after_query="$(target_index_state source-db postgres appdb 5432)"
repository_jobs_after_query="$(repository_job_count)"
clone_cluster_after_query="$(clone_cluster_state)"
clone_manifest_after_query="$(clone_manifest_state)"
clone_index_after_query="$(target_index_state clone-db clone_admin appdb 5432)"

[[ "$source_index_after_query" == "$source_index_before" ]] \
  || fail "Dashboard EXPLAIN ANALYZE kaynak index katalogunu degistirdi"
[[ "$repository_jobs_after_query" == "0" ]] \
  || fail "Dashboard EXPLAIN ANALYZE repository cluster'da job database birakti"
[[ "$clone_cluster_after_query" == "$clone_cluster_before" ]] \
  || fail "Dashboard EXPLAIN ANALYZE clone job database birakti"
[[ "$clone_manifest_after_query" == "$clone_manifest_before" ]] \
  || fail "Dashboard EXPLAIN ANALYZE clone manifestini degistirdi"
[[ "$clone_index_after_query" == "$clone_index_before" ]] \
  || fail "Dashboard EXPLAIN ANALYZE clone template index katalogunu degistirdi"
[[ "$query_endpoint_ok" == true ]] \
  || fail "Dashboard query EXPLAIN ANALYZE endpoint cagrisi basarisiz"

query_runtime_summary="$("$python_bin" - "$query_response_file" "$query_id" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)

validation = result.get("validation")
checks = {
    "queryId": str(result.get("queryId")) == sys.argv[2],
    "status=RUNTIME_VALIDATED": result.get("status") == "RUNTIME_VALIDATED",
    "statementClass=READ_ONLY_SELECT": isinstance(validation, dict)
    and validation.get("statementClass") == "READ_ONLY_SELECT",
    "planPreflight=READ_ONLY": isinstance(validation, dict)
    and validation.get("planPreflight") == "READ_ONLY",
    "transactionReadOnly=true": isinstance(validation, dict)
    and validation.get("transactionReadOnly") is True,
    "runnerPolicyRevision=1": isinstance(validation, dict)
    and validation.get("runnerPolicyRevision") == 1,
    "plan": isinstance(validation, dict)
    and isinstance(validation.get("plan"), dict)
    and isinstance(validation["plan"].get("Plan"), dict),
    "executionTarget=DISPOSABLE_CLONE": result.get("executionTarget")
    == "DISPOSABLE_CLONE",
    "sourceDdlExecuted=false": result.get("sourceDdlExecuted") is False,
    "cloneDdlExecuted=false": result.get("cloneDdlExecuted") is False,
    "cloneDestroyed=true": result.get("cloneDestroyed") is True,
}
failed = [name for name, accepted in checks.items() if not accepted]
if failed:
    raise SystemExit("query runtime acceptance failed: " + ", ".join(failed))

print(
    "status=RUNTIME_VALIDATED, readOnly=true, execution="
    f"{validation.get('executionTimeMs')}ms"
)
PY
)" || fail "Dashboard query runtime yaniti kabul sozlesmesini karsilamadi"
pass "${query_runtime_summary}"
pass "Dashboard sorgusu tek disposable clone'da, index/DDL olmadan calisti ve temizlendi"

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

endpoint_call_ok=false
if docker compose --profile real-validation exec -T \
  -e ACCEPTANCE_QUERY_ID="$query_id" \
  -e ACCEPTANCE_SERVER_ID="$server_id" \
  -e ACCEPTANCE_DATABASE_ID="$database_id" \
  -e ACCEPTANCE_CANDIDATE_ID="$candidate_id" \
  -e ADVISOR_API_TOKEN="$ADVISOR_API_TOKEN" \
  api python - >"$response_file" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ.get("ADVISOR_API_TOKEN", "")
if not token.startswith("adv_pat_v1_"):
    raise SystemExit("ADVISOR_API_TOKEN is not configured")

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
        "Authorization": f"Bearer {token}",
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
    "statementClass=READ_ONLY_SELECT": isinstance(validation, dict)
    and validation.get("statementClass") == "READ_ONLY_SELECT",
    "planPreflight=READ_ONLY": isinstance(validation, dict)
    and validation.get("planPreflight") == "READ_ONLY",
    "transactionReadOnly=true": isinstance(validation, dict)
    and validation.get("transactionReadOnly") is True,
    "runnerPolicyRevision=1": isinstance(validation, dict)
    and validation.get("runnerPolicyRevision") == 1,
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
