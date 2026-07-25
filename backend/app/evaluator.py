from __future__ import annotations

import asyncio
import hashlib
import json
import re
import secrets
from collections.abc import Mapping
from datetime import datetime, timezone
from functools import lru_cache
from typing import Any, Literal

import psycopg
from fastapi import FastAPI, Header, HTTPException, status
from psycopg import sql
from psycopg.rows import dict_row
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.schemas import IndexAdvice, InternalIndexEvaluationRequest


class EvaluatorSettings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    evaluator_database_url: str = (
        "postgresql://advisor_evaluator:advisor_dev_evaluator@localhost:5432/appdb"
    )
    evaluator_allowed_server_alias: str = "test-source"
    evaluator_allowed_database: str = "appdb"
    evaluator_token: str = "advisor-dev-evaluator-token"
    evaluator_statement_timeout_ms: int = Field(default=2_000, ge=100, le=10_000)
    evaluator_lock_timeout_ms: int = Field(default=250, ge=50, le=2_000)
    evaluator_min_improvement_percent: float = Field(default=10.0, ge=1, le=90)


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
    query = re.sub(r"\binterval\s+(\$\d+)\b", r"\1::interval", query, flags=re.IGNORECASE)
    query = re.sub(r"\bdate\s+(\$\d+)\b", r"\1::date", query, flags=re.IGNORECASE)
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
            settings.evaluator_database_url,
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


app = FastAPI(
    title="PostgreSQL Advisor HypoPG Evaluator",
    version="1.0.0-iteration-2.2",
    description="Internal, SELECT-only hypothetical index plan evaluator.",
)
_evaluation_slots = asyncio.Semaphore(2)


def _authorized(token: str | None) -> None:
    expected = get_evaluator_settings().evaluator_token
    if not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Gecersiz evaluator tokeni.")


@app.get("/health")
async def health() -> dict[str, Any]:
    settings = get_evaluator_settings()
    try:
        with psycopg.connect(settings.evaluator_database_url, connect_timeout=3) as connection:
            with connection.cursor(row_factory=dict_row) as cursor:
                cursor.execute(
                    "SELECT current_database() AS database_name, current_user AS role_name, "
                    "(SELECT extversion FROM pg_extension WHERE extname='hypopg') AS hypopg_version, "
                    "current_setting('default_transaction_read_only') AS default_read_only"
                )
                result = dict(cursor.fetchone())
        healthy = (
            result["database_name"] == settings.evaluator_allowed_database
            and result["role_name"] == "advisor_evaluator"
            and bool(result["hypopg_version"])
            and result["default_read_only"] == "on"
        )
        if not healthy:
            raise RuntimeError("Evaluator capability mismatch")
        return {"status": "healthy", **result, "ddlExecuted": False}
    except Exception as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="Evaluator hazir degil.") from exc


@app.post("/internal/v1/index-evaluations", response_model=IndexAdvice)
async def index_evaluation(
    payload: InternalIndexEvaluationRequest,
    x_evaluator_token: str | None = Header(default=None, alias="X-Evaluator-Token"),
) -> dict[str, Any]:
    _authorized(x_evaluator_token)
    async with _evaluation_slots:
        return await asyncio.to_thread(_evaluate, payload)
