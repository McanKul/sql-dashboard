from __future__ import annotations

import asyncio
import hashlib
import json
import re
import secrets
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Literal

import psycopg
from fastapi import FastAPI, Header, HTTPException, status
from psycopg import sql
from psycopg.rows import dict_row
from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.conninfo import resolve_conninfo
from app.version import APPLICATION_VERSION
from app.clone_evaluator import (
    CloneEvaluationStop,
    _assert_read_only_select,
    _decode_explain_row,
    _rewrite_pgss_typed_parameters,
    _runtime_statement,
    _walk_plan,
)
from app.schemas import (
    IndexAdvice,
    InternalIndexEvaluationRequest,
    InternalQueryExplainAnalyzeRequest,
    QueryExplainAnalyzeResult,
    SOURCE_EXPLAIN_MAX_BIND_VALUES,
)


class EvaluatorSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", extra="ignore", hide_input_in_errors=True
    )

    # EVALUATOR_DATABASE_URL remains a backwards-compatible explicit override.
    evaluator_database_url: str | None = None
    evaluator_database_host: str = "localhost"
    evaluator_database_port: int = Field(default=5432, ge=1, le=65_535)
    evaluator_database_name: str = "appdb"
    evaluator_database_user: str = "advisor_evaluator"
    evaluator_database_password: str = "advisor_dev_evaluator"
    evaluator_database_sslmode: str | None = None
    evaluator_allowed_server_alias: str = "test-source"
    evaluator_allowed_database: str = "appdb"
    evaluator_token: str = "advisor-dev-evaluator-token"
    evaluator_statement_timeout_ms: int = Field(default=2_000, ge=100, le=10_000)
    evaluator_lock_timeout_ms: int = Field(default=250, ge=50, le=2_000)
    evaluator_min_improvement_percent: float = Field(default=10.0, ge=1, le=90)
    evaluator_runtime_statement_timeout_ms: int = Field(
        default=120_000,
        ge=1_000,
        le=300_000,
    )
    evaluator_runtime_lock_timeout_ms: int = Field(default=5_000, ge=50, le=30_000)
    evaluator_runtime_transaction_timeout_ms: int = Field(
        default=125_000,
        ge=1_500,
        le=305_000,
    )

    @property
    def evaluator_database_conninfo(self) -> str:
        return resolve_conninfo(
            self.evaluator_database_url,
            host=self.evaluator_database_host,
            port=self.evaluator_database_port,
            dbname=self.evaluator_database_name,
            user=self.evaluator_database_user,
            password=self.evaluator_database_password,
            sslmode=self.evaluator_database_sslmode,
        )

    @model_validator(mode="after")
    def database_connection_is_valid(self) -> EvaluatorSettings:
        _ = self.evaluator_database_conninfo
        if (
            self.evaluator_runtime_transaction_timeout_ms
            <= self.evaluator_runtime_statement_timeout_ms
        ):
            raise ValueError(
                "runtime transaction timeout statement timeout'tan uzun olmali"
            )
        return self


@lru_cache
def get_evaluator_settings() -> EvaluatorSettings:
    return EvaluatorSettings()


class EvaluationStop(Exception):
    def __init__(self, result_status: str, reason_code: str, message: str):
        super().__init__(message)
        self.result_status = result_status
        self.reason_code = reason_code
        self.message = message


_PARAMETER = re.compile(r"\$\d+\b")
_SAFE_START = re.compile(r"^(SELECT|WITH)\b", re.IGNORECASE)
_WRITE_KEYWORD = re.compile(
    r"\b(INSERT|UPDATE|DELETE|MERGE|COPY|CALL|DO|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE|VACUUM|ANALYZE|REFRESH)\b",
    re.IGNORECASE,
)


def _advice(
    result_status: Literal["VALIDATED", "NO_IMPROVEMENT", "UNAVAILABLE", "UNSAFE", "INSUFFICIENT"],
    reason_code: str,
    message: str,
    **extra: Any,
) -> dict[str, Any]:
    return {
        "status": result_status,
        "reasonCode": reason_code,
        "message": message,
        "candidate": extra.get("candidate"),
        "validation": extra.get("validation"),
        "confidence": extra.get("confidence"),
        "ddlExecuted": False,
    }


def _replay_sql(normalized_sql: str) -> tuple[str, Literal["GENERIC_PLAN", "PLAIN_PLAN"]]:
    query = normalized_sql.strip()
    if query.endswith(";"):
        query = query[:-1].rstrip()
    if not query or ";" in query or "\x00" in query:
        raise EvaluationStop("UNSAFE", "MULTI_STATEMENT_OR_INVALID_SQL", "Yalniz tek bir sorgu planlanabilir.")
    if not _SAFE_START.match(query) or _WRITE_KEYWORD.search(query):
        raise EvaluationStop(
            "UNSAFE",
            "SELECT_ONLY",
            "Bu iterasyon yalniz SELECT sorgularini salt-okunur planda dogrular.",
        )

    # pg_stat_statements typed string literals such as INTERVAL '30 days' are
    # normalized as `interval $1`, which is not directly replayable.  PG18's
    # GENERIC_PLAN accepts parameters once the equivalent cast is explicit.
    query = _rewrite_pgss_typed_parameters(query)
    mode: Literal["GENERIC_PLAN", "PLAIN_PLAN"] = (
        "GENERIC_PLAN" if _PARAMETER.search(query) else "PLAIN_PLAN"
    )
    return query, mode


def _plan(cursor: psycopg.Cursor[Any], query: str, mode: str) -> dict[str, Any]:
    option = ", GENERIC_PLAN TRUE" if mode == "GENERIC_PLAN" else ""
    cursor.execute(sql.SQL(f"EXPLAIN (FORMAT JSON{option}) ") + sql.SQL(query))
    row = cursor.fetchone()
    if row is None:
        raise EvaluationStop("UNAVAILABLE", "EMPTY_PLAN", "PostgreSQL sorgu plani dondurmedi.")
    # The evaluator connection uses dict_row for all catalog reads.  EXPLAIN's
    # generated column label is driver/version dependent, so consume its only
    # value instead of relying on a positional row or a literal key.
    raw = next(iter(row.values())) if isinstance(row, Mapping) else row[0]
    if isinstance(raw, str):
        raw = json.loads(raw)
    return raw[0]


def _walk_plan(node: dict[str, Any]):
    yield node
    for child in node.get("Plans") or []:
        yield from _walk_plan(child)


def _access_method(plan: dict[str, Any], table_name: str) -> str | None:
    for node in _walk_plan(plan["Plan"]):
        if node.get("Relation Name") == table_name:
            return str(node.get("Node Type"))
    return None


def _uses_hypothetical_index(plan: dict[str, Any], index_oid: int, index_name: str) -> bool:
    oid_marker = f"<{index_oid}>"
    for node in _walk_plan(plan["Plan"]):
        used_name = str(node.get("Index Name") or "")
        if used_name == index_name or oid_marker in used_name:
            return True
    return False


def _proposed_index_name(
    schema_name: str,
    table_name: str,
    column_names: str | list[str],
) -> str:
    columns = [column_names] if isinstance(column_names, str) else column_names
    readable = re.sub(
        r"[^a-z0-9_]+", "_", f"{table_name}_{'_'.join(columns)}".lower()
    ).strip("_")
    digest = hashlib.sha256(
        f"{schema_name}.{table_name}:{','.join(columns)}".encode()
    ).hexdigest()[:8]
    return f"idx_advisor_{readable[:38]}_{digest}"


def _proposed_index_sql(
    connection: psycopg.Connection[Any],
    schema_name: str,
    table_name: str,
    column_names: str | list[str],
) -> str:
    columns = [column_names] if isinstance(column_names, str) else column_names
    index_name = _proposed_index_name(schema_name, table_name, columns)
    statement = sql.SQL("CREATE INDEX CONCURRENTLY {} ON {}.{} USING btree ({});").format(
        sql.Identifier(index_name),
        sql.Identifier(schema_name),
        sql.Identifier(table_name),
        sql.SQL(", ").join(sql.Identifier(column) for column in columns),
    )
    return statement.as_string(connection)


def _evaluate(payload: InternalIndexEvaluationRequest) -> dict[str, Any]:
    settings = get_evaluator_settings()
    if payload.serverAlias != settings.evaluator_allowed_server_alias:
        return _advice(
            "UNAVAILABLE",
            "SOURCE_NOT_CONFIGURED",
            "Bu kaynak icin ayri HypoPG evaluator baglantisi yapilandirilmamis.",
        )
    if payload.databaseName != settings.evaluator_allowed_database:
        return _advice(
            "UNAVAILABLE",
            "DATABASE_NOT_CONFIGURED",
            "Bu veritabani HypoPG evaluator izin listesinde degil.",
        )
    if payload.sampleCount < 2 or payload.occurrences < 5 or payload.rowsProcessed < 1_000:
        return _advice(
            "INSUFFICIENT",
            "INSUFFICIENT_PREDICATE_EVIDENCE",
            "Plan onerisi icin daha fazla predicate ornegi birikmeli.",
        )
    if payload.schemaName == "unknown" or not 1 <= len(payload.columns) <= 2:
        return _advice(
            "UNSAFE",
            "UNRESOLVED_OR_COMPOSITE_PREDICATE",
            "Canli kaynakta index adayi katalog kimligi guvenle cozumlenemedi.",
        )

    try:
        replay_sql, plan_mode = _replay_sql(payload.normalizedSql)
    except EvaluationStop as exc:
        return _advice(exc.result_status, exc.reason_code, exc.message)

    connection: psycopg.Connection[Any] | None = None
    try:
        connection = psycopg.connect(
            settings.evaluator_database_conninfo,
            autocommit=True,
            row_factory=dict_row,
            connect_timeout=3,
        )
        with connection.cursor() as cursor:
            cursor.execute("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            cursor.execute(
                "SELECT set_config('statement_timeout', %s, true), "
                "set_config('lock_timeout', %s, true), "
                "set_config('idle_in_transaction_session_timeout', '3s', true), "
                "set_config('transaction_timeout', '4s', true), "
                "set_config('row_security', 'on', true), "
                "set_config('jit', 'off', true)",
                (f"{settings.evaluator_statement_timeout_ms}ms", f"{settings.evaluator_lock_timeout_ms}ms"),
            )
            cursor.execute(
                "SELECT current_database() AS database_name, d.oid::bigint AS database_id, "
                "e.extversion AS hypopg_version "
                "FROM pg_database d "
                "LEFT JOIN pg_extension e ON e.extname = 'hypopg' "
                "WHERE d.datname = current_database()"
            )
            database = cursor.fetchone()
            if not database or database["database_name"] != payload.databaseName:
                raise EvaluationStop("UNAVAILABLE", "DATABASE_MISMATCH", "Evaluator farkli bir veritabanina baglandi.")
            if int(database["database_id"]) != payload.databaseId:
                raise EvaluationStop(
                    "UNSAFE",
                    "STALE_DATABASE_OID",
                    "Repository veritabani kimligi canli kaynakla eslesmiyor; yeni snapshot beklenmeli.",
                )
            if not database["hypopg_version"]:
                raise EvaluationStop("UNAVAILABLE", "HYPOPG_NOT_INSTALLED", "Kaynak veritabaninda HypoPG etkin degil.")

            cursor.execute(
                """
                SELECT c.oid::bigint AS relation_id,
                       c.relkind,
                       c.relrowsecurity,
                       array_agg(a.attnum ORDER BY requested.ordinality)::smallint[] AS attnums,
                       has_table_privilege(current_user, c.oid, 'SELECT') AS can_select,
                       pg_total_relation_size(c.oid)::bigint AS table_size_bytes
                  FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  CROSS JOIN unnest(%s::text[]) WITH ORDINALITY AS requested(column_name, ordinality)
                  JOIN pg_attribute a
                    ON a.attrelid = c.oid AND a.attname = requested.column_name
                 WHERE n.nspname = %s
                   AND c.relname = %s
                   AND a.attnum > 0
                   AND NOT a.attisdropped
                 GROUP BY c.oid, c.relkind, c.relrowsecurity
                HAVING count(*) = %s
                """,
                (payload.columns, payload.schemaName, payload.tableName, len(payload.columns)),
            )
            relation = cursor.fetchone()
            if not relation or int(relation["relation_id"]) != payload.relationId:
                raise EvaluationStop(
                    "UNSAFE",
                    "STALE_OR_UNRESOLVED_RELATION",
                    "Repository tablo/kolon kimligi canli kaynakla eslesmiyor; yeni snapshot beklenmeli.",
                )
            if relation["relkind"] not in {"r", "p"} or not relation["can_select"]:
                raise EvaluationStop("UNSAFE", "RELATION_NOT_ELIGIBLE", "Tablo salt-okunur planlama icin uygun degil.")
            if relation["relrowsecurity"]:
                raise EvaluationStop(
                    "UNSAFE",
                    "ROW_LEVEL_SECURITY_ACTIVE",
                    "RLS etkin tabloda uygulama rolunden farkli plan onerisi verilmez.",
                )

            cursor.execute(
                """
                SELECT bool_and(EXISTS (
                           SELECT 1
                             FROM pg_amop operator_map
                             JOIN pg_opfamily family ON family.oid = operator_map.amopfamily
                             JOIN pg_am access_method ON access_method.oid = family.opfmethod
                            WHERE operator_map.amopopr = requested.operator_oid
                              AND operator_map.amopstrategy BETWEEN 1 AND 5
                              AND access_method.amname = 'btree'
                       )) AS btree_compatible
                  FROM unnest(%s::oid[]) AS requested(operator_oid)
                """,
                (payload.operatorOids,),
            )
            if not cursor.fetchone()["btree_compatible"]:
                raise EvaluationStop(
                    "UNSAFE",
                    "OPERATOR_NOT_BTREE_COMPATIBLE",
                    "Predicate operatoru basit B-tree index dogrulamasi icin uygun degil.",
                )

            cursor.execute(
                """
                SELECT index_class.relname AS index_name
                  FROM pg_index i
                  JOIN pg_class index_class ON index_class.oid = i.indexrelid
                  JOIN pg_am am ON am.oid = index_class.relam
                 WHERE i.indrelid = %s
                   AND am.amname = 'btree'
                   AND i.indisvalid
                   AND i.indisready
                   AND i.indpred IS NULL
                   AND i.indexprs IS NULL
                   AND i.indnkeyatts >= %s
                   AND (i.indkey::smallint[])[0:%s] = %s::smallint[]
                 LIMIT 1
                """,
                (
                    relation["relation_id"],
                    len(payload.columns),
                    len(payload.columns) - 1,
                    relation["attnums"],
                ),
            )
            existing = cursor.fetchone()
            if existing:
                raise EvaluationStop(
                    "NO_IMPROVEMENT",
                    "EQUIVALENT_INDEX_EXISTS",
                    f"{existing['index_name']} ayni kolon sirasi ile baslayan gecerli bir B-tree indexidir; yeni SQL onerilmedi.",
                )

            cursor.execute("SELECT advisor_hypopg.hypopg_reset()")
            baseline = _plan(cursor, replay_sql, plan_mode)
            hypothetical_ddl = sql.SQL("CREATE INDEX ON {}.{} USING btree ({})").format(
                sql.Identifier(payload.schemaName),
                sql.Identifier(payload.tableName),
                sql.SQL(", ").join(sql.Identifier(column) for column in payload.columns),
            ).as_string(connection)
            cursor.execute(
                "SELECT indexrelid::bigint, indexname FROM advisor_hypopg.hypopg_create_index(%s)",
                (hypothetical_ddl,),
            )
            hypothetical_index = cursor.fetchone()
            hypothetical = _plan(cursor, replay_sql, plan_mode)
            cursor.execute(
                "SELECT advisor_hypopg.hypopg_relation_size(%s::oid)::bigint AS estimated_size",
                (hypothetical_index["indexrelid"],),
            )
            estimated_size = int(cursor.fetchone()["estimated_size"] or 0)

            baseline_cost = float(baseline["Plan"]["Total Cost"])
            hypothetical_cost = float(hypothetical["Plan"]["Total Cost"])
            reduction = max(0.0, (baseline_cost - hypothetical_cost) / baseline_cost * 100) if baseline_cost else 0.0
            used = _uses_hypothetical_index(
                hypothetical,
                int(hypothetical_index["indexrelid"]),
                str(hypothetical_index["indexname"]),
            )
            validation = {
                "mode": plan_mode,
                "hypopgVersion": str(database["hypopg_version"]),
                "baselineTotalCost": round(baseline_cost, 2),
                "hypotheticalTotalCost": round(hypothetical_cost, 2),
                "costReductionPercent": round(reduction, 2),
                "hypotheticalIndexUsed": used,
                "baselineAccess": _access_method(baseline, payload.tableName),
                "hypotheticalAccess": _access_method(hypothetical, payload.tableName),
                "estimatedIndexSizeBytes": estimated_size,
                "tableSizeBytes": int(relation["table_size_bytes"] or 0),
                "evaluatedAt": datetime.now(timezone.utc),
            }
            if not used or reduction < settings.evaluator_min_improvement_percent:
                return _advice(
                    "NO_IMPROVEMENT",
                    "COST_REDUCTION_NOT_CONFIRMED",
                    "Sanal index planda yeterli maliyet iyilesmesi saglamadi; index SQL'i onerilmedi.",
                    validation=validation,
                )

            confidence_level = (
                "HIGH"
                if reduction >= 30 and payload.occurrences >= 20 and payload.rowsProcessed >= 10_000
                else "MEDIUM"
            )
            confidence_reasons = [
                "Sanal index PostgreSQL planinda kullanildi.",
                f"Tahmini plan maliyeti %{reduction:.1f} azaldi.",
            ]
            if confidence_level == "HIGH":
                confidence_reasons.append("Predicate ornek ve satir hacmi karar esigini asti.")
            return _advice(
                "VALIDATED",
                "COST_REDUCTION_CONFIRMED",
                "HypoPG sanal indexi planda kullanildi ve tahmini maliyeti anlamli bicimde dusurdu.",
                candidate={
                    "method": "btree",
                    "columns": payload.columns,
                    "createIndexSql": _proposed_index_sql(
                        connection, payload.schemaName, payload.tableName, payload.columns
                    ),
                    "copyable": True,
                },
                validation=validation,
                confidence={"level": confidence_level, "reasons": confidence_reasons},
            )
    except EvaluationStop as exc:
        return _advice(exc.result_status, exc.reason_code, exc.message)
    except psycopg.errors.QueryCanceled:
        return _advice("UNAVAILABLE", "PLAN_TIMEOUT", "Plan dogrulamasi guvenli sure sinirini asti.")
    except psycopg.Error:
        return _advice(
            "UNSAFE",
            "QUERY_NOT_REPLAYABLE",
            "Normalize sorgu salt-okunur generic plan olarak guvenle yeniden oynatilamadi.",
        )
    except Exception:
        return _advice("UNAVAILABLE", "EVALUATOR_ERROR", "HypoPG evaluator beklenmeyen bir hata verdi.")
    finally:
        if connection is not None:
            try:
                connection.rollback()
            except psycopg.Error:
                pass
            try:
                connection.execute("SELECT advisor_hypopg.hypopg_reset()")
            except psycopg.Error:
                pass
            connection.close()


SOURCE_READ_ONLY_POLICY_REVISION = 1


def _source_replay_query(
    normalized_sql: str,
    bind_values: list[str | int | float | bool | None] | None = None,
) -> tuple[str, tuple[str | int | float | bool | None, ...]]:
    """Apply the shared SELECT gate with an ERP-sized source bind envelope."""

    values = list(bind_values or [])
    if "\x00" in normalized_sql:
        raise CloneEvaluationStop(
            "UNSAFE",
            "MULTI_STATEMENT_OR_INVALID_SQL",
            "Yalniz tek bir SELECT sorgusu calistirilabilir.",
        )
    query, parameter_numbers = _assert_read_only_select(normalized_sql)
    query = _rewrite_pgss_typed_parameters(query)
    if not parameter_numbers:
        if values:
            raise CloneEvaluationStop(
                "UNSAFE",
                "UNEXPECTED_REPLAY_VALUES",
                "Parametresiz sorgu icin bind degeri gonderilemez.",
            )
        return query, ()

    highest_parameter = max(parameter_numbers)
    if (
        highest_parameter > SOURCE_EXPLAIN_MAX_BIND_VALUES
        or set(parameter_numbers) != set(range(1, highest_parameter + 1))
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "INVALID_PARAMETER_LAYOUT",
            "Normalize sorgu parametreleri $1'den baslayan bitisik ve en fazla "
            f"{SOURCE_EXPLAIN_MAX_BIND_VALUES} deger olmali.",
        )
    if len(values) != highest_parameter:
        raise CloneEvaluationStop(
            "UNAVAILABLE",
            "REPLAY_FIXTURE_VALUE_COUNT_MISMATCH",
            "Bind degeri sayisi normalize sorgunun parametreleriyle eslesmiyor.",
        )
    return query, tuple(values)


def _source_query_result(
    payload: InternalQueryExplainAnalyzeRequest,
    result_status: Literal["RUNTIME_VALIDATED", "UNAVAILABLE", "UNSAFE"],
    reason_code: str,
    message: str,
    *,
    validation: dict[str, Any] | None = None,
    source_executed: bool = False,
    transaction_rolled_back: bool = False,
) -> dict[str, Any]:
    return {
        "status": result_status,
        "reasonCode": reason_code,
        "message": message,
        "queryId": payload.queryId,
        "validation": validation,
        "executionTarget": "SOURCE_DATABASE",
        "sourceExecuted": source_executed,
        "sourceDdlExecuted": False,
        "transactionRolledBack": transaction_rolled_back,
    }


def _assert_source_read_only_plan(plan: dict[str, Any]) -> None:
    """Reject every PostgreSQL plan shape capable of table writes or row locks.

    Foreign/custom scans remain eligible on the real source because many ERP
    SELECTs legitimately use FDWs or extensions.  The explicit READ ONLY
    transaction and low-privilege source role remain the authoritative database
    boundary after the lexical and plain-plan preflight gates.
    """

    unsafe_node_types = {"ModifyTable", "LockRows"}
    unsafe_operations = {"INSERT", "UPDATE", "DELETE", "MERGE"}
    for node in _walk_plan(plan["Plan"]):
        if str(node.get("Node Type") or "") in unsafe_node_types or str(
            node.get("Operation") or ""
        ).upper() in unsafe_operations:
            raise CloneEvaluationStop(
                "UNSAFE",
                "READ_ONLY_PLAN_REQUIRED",
                "PostgreSQL plan preflight'i yazma veya satir kilidi dugumu tespit etti.",
            )


def _begin_source_read_only_transaction(
    cursor: psycopg.Cursor[Any],
    settings: EvaluatorSettings,
) -> None:
    cursor.execute("BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED READ ONLY")
    cursor.execute(
        "SELECT set_config('statement_timeout', %s, true), "
        "set_config('lock_timeout', %s, true), "
        "set_config('transaction_timeout', %s, true), "
        "set_config('idle_in_transaction_session_timeout', %s, true), "
        "set_config('row_security', 'on', true), "
        "set_config('standard_conforming_strings', 'on', true)",
        (
            f"{settings.evaluator_runtime_statement_timeout_ms}ms",
            f"{settings.evaluator_runtime_lock_timeout_ms}ms",
            f"{settings.evaluator_runtime_transaction_timeout_ms}ms",
            f"{settings.evaluator_runtime_transaction_timeout_ms}ms",
        ),
    )


def _source_connection_guard(
    cursor: psycopg.Cursor[Any],
    settings: EvaluatorSettings,
    payload: InternalQueryExplainAnalyzeRequest,
) -> dict[str, Any]:
    cursor.execute(
        """
        SELECT current_database() AS database_name,
               database.oid::bigint AS database_id,
               current_user AS role_name,
               session_user AS session_role_name,
               current_setting('server_version') AS postgres_version,
               current_setting('transaction_read_only') = 'on'
                   AS transaction_read_only,
               current_setting('default_transaction_read_only') = 'on'
                   AS default_read_only,
               current_setting('row_security') = 'on' AS row_security,
               extract(epoch FROM current_setting('statement_timeout')::interval) * 1000 = %s
                   AS statement_timeout_exact,
               extract(epoch FROM current_setting('lock_timeout')::interval) * 1000 = %s
                   AS lock_timeout_exact,
               extract(epoch FROM current_setting('transaction_timeout')::interval) * 1000 = %s
                   AS transaction_timeout_exact,
               role.rolcanlogin AS role_can_login,
               role.rolconnlimit = 2 AS role_connection_limit_exact,
               NOT role.rolinherit AS role_noinherit,
               NOT role.rolsuper AS role_not_superuser,
               NOT role.rolcreatedb AS role_not_createdb,
               NOT role.rolcreaterole AS role_not_createrole,
               NOT role.rolreplication AS role_not_replication,
               NOT role.rolbypassrls AS role_not_bypassrls,
               NOT EXISTS (
                   SELECT 1
                     FROM pg_auth_members membership
                    WHERE membership.member = role.oid
               ) AS role_has_no_memberships,
               NOT has_database_privilege(
                   current_user, current_database(), 'CREATE'
               ) AS database_create_revoked,
               NOT EXISTS (
                   SELECT 1
                     FROM pg_namespace namespace
                    WHERE left(namespace.nspname, 8) <> 'pg_temp_'
                      AND left(namespace.nspname, 14) <> 'pg_toast_temp_'
                      AND has_schema_privilege(
                          current_user, namespace.oid, 'CREATE'
                      )
               ) AS schema_create_revoked
          FROM pg_database database
          JOIN pg_roles role ON role.rolname = current_user
         WHERE database.datname = current_database()
        """,
        (
            settings.evaluator_runtime_statement_timeout_ms,
            settings.evaluator_runtime_lock_timeout_ms,
            settings.evaluator_runtime_transaction_timeout_ms,
        ),
    )
    guard = cursor.fetchone()
    if not guard:
        raise CloneEvaluationStop(
            "UNSAFE",
            "SOURCE_POLICY_MISMATCH",
            "Kaynak evaluator baglanti policy'si dogrulanamadi.",
        )
    if guard["database_name"] != payload.databaseName:
        raise CloneEvaluationStop(
            "UNAVAILABLE",
            "DATABASE_MISMATCH",
            "Evaluator farkli bir kaynak veritabanina baglandi.",
        )
    if int(guard["database_id"]) != payload.databaseId:
        raise CloneEvaluationStop(
            "UNSAFE",
            "STALE_DATABASE_OID",
            "Repository veritabani kimligi canli kaynakla eslesmiyor; yeni snapshot beklenmeli.",
        )
    if (
        guard["role_name"] != settings.evaluator_database_user
        or guard["session_role_name"] != settings.evaluator_database_user
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "SOURCE_ROLE_MISMATCH",
            "Kaynak EXPLAIN ANALYZE beklenen dusuk yetkili rolle calismiyor.",
        )
    required_true = (
        "transaction_read_only",
        "default_read_only",
        "row_security",
        "statement_timeout_exact",
        "lock_timeout_exact",
        "transaction_timeout_exact",
        "role_can_login",
        "role_connection_limit_exact",
        "role_noinherit",
        "role_not_superuser",
        "role_not_createdb",
        "role_not_createrole",
        "role_not_replication",
        "role_not_bypassrls",
        "role_has_no_memberships",
        "database_create_revoked",
        "schema_create_revoked",
    )
    if any(
        str(guard.get(key)).lower() not in {"true", "on", "t", "1"}
        for key in required_true
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "SOURCE_POLICY_MISMATCH",
            "Kaynak evaluator aktif transaction, rol veya ACL policy'si salt-okunur degil.",
        )
    return dict(guard)


def _source_plan_preflight(
    cursor: psycopg.Cursor[Any],
    runtime_statement: sql.Composable,
) -> None:
    cursor.execute(
        sql.SQL("EXPLAIN (ANALYZE FALSE, VERBOSE TRUE, FORMAT JSON) ")
        + runtime_statement,
        prepare=True,
    )
    _assert_source_read_only_plan(_decode_explain_row(cursor.fetchone()))


def _source_query_validation(
    plan: dict[str, Any],
    guard: Mapping[str, Any],
) -> dict[str, Any]:
    root = plan["Plan"]
    return {
        "mode": "EXPLAIN_ANALYZE",
        "statementClass": "READ_ONLY_SELECT",
        "planPreflight": "READ_ONLY",
        "transactionReadOnly": True,
        "safetyPolicyRevision": SOURCE_READ_ONLY_POLICY_REVISION,
        "postgresVersion": str(guard["postgres_version"]),
        "executionRole": str(guard["role_name"]),
        "databaseId": int(guard["database_id"]),
        "executionTimeMs": float(plan.get("Execution Time") or 0),
        "planningTimeMs": float(plan.get("Planning Time") or 0),
        "sharedHitBlocks": int(root.get("Shared Hit Blocks") or 0),
        "sharedReadBlocks": int(root.get("Shared Read Blocks") or 0),
        "tempReadBlocks": int(root.get("Temp Read Blocks") or 0),
        "tempWrittenBlocks": int(root.get("Temp Written Blocks") or 0),
        "walRecords": int(root.get("WAL Records") or 0),
        "walBytes": int(root.get("WAL Bytes") or 0),
        "plan": plan,
        "evaluatedAt": datetime.now(timezone.utc),
    }


def _friendly_source_gate_message(exc: CloneEvaluationStop) -> str:
    if exc.reason_code == "SELECT_ONLY":
        return "Ana veritabaninda EXPLAIN ANALYZE yalniz salt-okunur SELECT sorgulari icin calisir."
    if exc.reason_code == "REPLAY_FIXTURE_VALUE_COUNT_MISMATCH":
        return "Bind degeri sayisi normalize sorgunun parametreleriyle eslesmiyor."
    return exc.message.replace("Disposable clone", "Kaynak").replace("Clone", "Kaynak")


def _evaluate_source_query(
    payload: InternalQueryExplainAnalyzeRequest,
) -> dict[str, Any]:
    settings = get_evaluator_settings()
    validation: dict[str, Any] | None = None
    source_executed = False
    transaction_started = False
    transaction_rolled_back = False
    connection: psycopg.Connection[Any] | None = None
    result = _source_query_result(
        payload,
        "UNAVAILABLE",
        "SOURCE_EXPLAIN_NOT_STARTED",
        "Ana veritabaninda EXPLAIN ANALYZE baslatilamadi.",
    )

    try:
        if payload.serverAlias != settings.evaluator_allowed_server_alias:
            raise CloneEvaluationStop(
                "UNAVAILABLE",
                "SOURCE_NOT_CONFIGURED",
                "Bu kaynak alias'i icin evaluator baglantisi yapilandirilmamis.",
            )
        if payload.databaseName != settings.evaluator_allowed_database:
            raise CloneEvaluationStop(
                "UNAVAILABLE",
                "DATABASE_NOT_CONFIGURED",
                "Bu veritabani kaynak evaluator izin listesinde degil.",
            )
        query, bind_values = _source_replay_query(
            payload.normalizedSql,
            payload.bindValues,
        )
        connection = psycopg.connect(
            settings.evaluator_database_conninfo,
            autocommit=True,
            row_factory=dict_row,
            connect_timeout=3,
            application_name="postgresql-advisor-source-explain",
        )
        with connection.cursor() as cursor:
            _begin_source_read_only_transaction(cursor, settings)
            transaction_started = True
            guard = _source_connection_guard(cursor, settings, payload)
            runtime_statement = _runtime_statement(cursor, query, bind_values)
            _source_plan_preflight(cursor, runtime_statement)
            source_executed = True
            cursor.execute(
                sql.SQL(
                    "EXPLAIN (ANALYZE TRUE, BUFFERS TRUE, WAL TRUE, TIMING TRUE, "
                    "SUMMARY TRUE, VERBOSE TRUE, SETTINGS TRUE, FORMAT JSON) "
                )
                + runtime_statement,
                prepare=True,
            )
            plan = _decode_explain_row(cursor.fetchone())
            _assert_source_read_only_plan(plan)
            validation = _source_query_validation(plan, guard)
            result = _source_query_result(
                payload,
                "RUNTIME_VALIDATED",
                "SOURCE_READ_ONLY_EXPLAIN_ANALYZE_COMPLETED",
                "Salt-okunur sorgu ana veritabaninda EXPLAIN ANALYZE ile calistirildi.",
                validation=validation,
                source_executed=True,
            )
    except CloneEvaluationStop as exc:
        result = _source_query_result(
            payload,
            exc.result_status,  # type: ignore[arg-type]
            exc.reason_code,
            _friendly_source_gate_message(exc),
            validation=validation,
            source_executed=source_executed,
        )
    except psycopg.errors.ReadOnlySqlTransaction:
        result = _source_query_result(
            payload,
            "UNSAFE",
            "READ_ONLY_TRANSACTION_VIOLATION",
            "Sorgu ana veritabani salt-okunur transaction policy'sini ihlal etti.",
            source_executed=source_executed,
        )
    except psycopg.errors.InsufficientPrivilege:
        result = _source_query_result(
            payload,
            "UNSAFE",
            "READ_ONLY_POLICY_REJECTED",
            "Sorgu dusuk yetkili kaynak evaluator rolu tarafindan reddedildi.",
            source_executed=source_executed,
        )
    except psycopg.errors.QueryCanceled:
        result = _source_query_result(
            payload,
            "UNAVAILABLE",
            "SOURCE_QUERY_TIMEOUT",
            "Ana veritabanindaki EXPLAIN ANALYZE sure sinirini asti.",
            source_executed=source_executed,
        )
    except psycopg.Error:
        result = _source_query_result(
            payload,
            "UNAVAILABLE",
            "SOURCE_DATABASE_ERROR",
            "Sorgu ana veritabaninda salt-okunur olarak yeniden oynatilamadi.",
            source_executed=source_executed,
        )
    except Exception:
        result = _source_query_result(
            payload,
            "UNAVAILABLE",
            "SOURCE_EVALUATOR_ERROR",
            "Kaynak evaluator beklenmeyen bir hata verdi.",
            source_executed=source_executed,
        )
    finally:
        if connection is not None:
            try:
                connection.rollback()
                transaction_rolled_back = transaction_started
            except psycopg.Error:
                transaction_rolled_back = False
            connection.close()

    result["sourceExecuted"] = source_executed
    result["transactionRolledBack"] = transaction_rolled_back
    if result["status"] == "RUNTIME_VALIDATED" and not transaction_rolled_back:
        result = _source_query_result(
            payload,
            "UNAVAILABLE",
            "SOURCE_ROLLBACK_FAILED",
            "Salt-okunur kaynak transaction'i temiz bicimde kapatilamadi.",
            validation=validation,
            source_executed=source_executed,
            transaction_rolled_back=False,
        )
    return result


app = FastAPI(
    title="PostgreSQL Advisor Source Evaluator",
    version=APPLICATION_VERSION,
    description=(
        "Internal HypoPG planner and read-only source EXPLAIN ANALYZE evaluator."
    ),
)
_evaluation_slots = asyncio.Semaphore(1)
_active_evaluations: set[asyncio.Task[dict[str, Any]]] = set()


class EvaluationBusy(Exception):
    """Raised when the single source/HypoPG admission slot is occupied."""


def _evaluation_finished(operation: asyncio.Task[dict[str, Any]]) -> None:
    _active_evaluations.discard(operation)
    if not operation.cancelled():
        operation.exception()


async def _run_serialized_evaluation(
    evaluator: Callable[[Any], dict[str, Any]],
    payload: Any,
) -> dict[str, Any]:
    """Admit one operation and keep its slot until the worker thread exits.

    There is intentionally no in-memory wait queue.  A disconnected caller
    cannot leave a source query scheduled to start minutes later.
    """

    if _evaluation_slots.locked():
        raise EvaluationBusy
    # asyncio.Semaphore.acquire() does not suspend when a permit is available;
    # the check and reservation are therefore atomic on this event loop.
    await _evaluation_slots.acquire()

    async def run() -> dict[str, Any]:
        try:
            return await asyncio.to_thread(evaluator, payload)
        finally:
            _evaluation_slots.release()

    operation = asyncio.create_task(run())
    _active_evaluations.add(operation)
    operation.add_done_callback(_evaluation_finished)
    return await asyncio.shield(operation)


def _authorized(token: str | None) -> None:
    expected = get_evaluator_settings().evaluator_token
    if not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Gecersiz evaluator tokeni.")


@app.get("/health")
async def health() -> dict[str, Any]:
    settings = get_evaluator_settings()
    if _evaluation_slots.locked():
        return {
            "status": "healthy",
            "busy": True,
            "sourceAlias": settings.evaluator_allowed_server_alias,
            "databaseName": settings.evaluator_allowed_database,
            "sourceReadOnlyExplain": True,
            "sourceDdlExecuted": False,
        }
    try:
        with psycopg.connect(settings.evaluator_database_conninfo, connect_timeout=3) as connection:
            with connection.cursor(row_factory=dict_row) as cursor:
                cursor.execute(
                    "SELECT current_database() AS database_name, current_user AS role_name, "
                    "(SELECT extversion FROM pg_extension WHERE extname='hypopg') AS hypopg_version, "
                    "current_setting('default_transaction_read_only') AS default_read_only"
                )
                result = dict(cursor.fetchone())
        healthy = (
            result["database_name"] == settings.evaluator_allowed_database
            and result["role_name"] == settings.evaluator_database_user
            and bool(result["hypopg_version"])
            and result["default_read_only"] == "on"
        )
        if not healthy:
            raise RuntimeError("Evaluator capability mismatch")
        return {
            "status": "healthy",
            "busy": False,
            "sourceAlias": settings.evaluator_allowed_server_alias,
            **result,
            "sourceReadOnlyExplain": True,
            "ddlExecuted": False,
        }
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Evaluator hazir degil.") from exc


@app.post("/internal/v1/index-evaluations", response_model=IndexAdvice)
async def index_evaluation(
    payload: InternalIndexEvaluationRequest,
    x_evaluator_token: str | None = Header(default=None, alias="X-Evaluator-Token"),
) -> dict[str, Any]:
    _authorized(x_evaluator_token)
    try:
        return await _run_serialized_evaluation(_evaluate, payload)
    except EvaluationBusy:
        return _advice(
            "UNAVAILABLE",
            "EVALUATOR_BUSY",
            "Evaluator baska bir plan veya kaynak sorgusu calistiriyor; daha sonra tekrar deneyin.",
        )


@app.post(
    "/internal/v1/query-explain-analyze",
    response_model=QueryExplainAnalyzeResult,
)
async def source_query_explain_analyze(
    payload: InternalQueryExplainAnalyzeRequest,
    x_evaluator_token: str | None = Header(default=None, alias="X-Evaluator-Token"),
) -> dict[str, Any]:
    _authorized(x_evaluator_token)
    try:
        return await _run_serialized_evaluation(_evaluate_source_query, payload)
    except EvaluationBusy:
        return _source_query_result(
            payload,
            "UNAVAILABLE",
            "SOURCE_EVALUATOR_BUSY",
            "Kaynak evaluator baska bir sorgu calistiriyor; bu istek baslatilmadi.",
        )
