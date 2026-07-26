from __future__ import annotations

import asyncio
import json
import math
import secrets
import statistics
import uuid
from collections import Counter
from collections.abc import Mapping
from datetime import datetime, timezone
from functools import lru_cache
from time import perf_counter
from typing import Any, Literal

import psycopg
from fastapi import FastAPI, Header, HTTPException, status
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.rows import dict_row
from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.conninfo import resolve_conninfo


class CloneEvaluatorSettings(BaseSettings):
    """Configuration for the clone-only runtime evaluator.

    Deliberately, there is no source database setting in this service.  The
    configured server must be a pre-populated, isolated clone cluster.
    """

    model_config = SettingsConfigDict(
        env_file=".env", extra="ignore", hide_input_in_errors=True
    )

    # CLONE_DATABASE_URL remains a backwards-compatible explicit override.
    clone_database_url: str | None = None
    clone_database_host: str = "localhost"
    clone_database_port: int = Field(default=55_432, ge=1, le=65_535)
    clone_database_name: str = "postgres"
    clone_database_user: str = "clone_admin"
    clone_database_password: str = "advisor_dev_clone_admin"
    clone_database_sslmode: str | None = None
    clone_template_database: str = "appdb"
    clone_admin_role: str = "clone_admin"
    clone_runner_role: str = "clone_runner"
    clone_runner_password: str = "advisor_dev_clone_runner"
    clone_evaluator_token: str = "advisor-dev-clone-evaluator-token"
    clone_statement_timeout_ms: int = Field(default=10_000, ge=100, le=120_000)
    clone_lock_timeout_ms: int = Field(default=1_000, ge=50, le=10_000)
    clone_transaction_timeout_ms: int = Field(default=15_000, ge=500, le=180_000)
    clone_warmup_runs: int = Field(default=1, ge=0, le=3)
    clone_measured_runs: int = Field(default=5, ge=1, le=9)
    clone_min_improvement_percent: float = Field(default=10.0, ge=0, le=90)
    clone_connect_timeout_seconds: int = Field(default=3, ge=1, le=15)

    @property
    def clone_database_conninfo(self) -> str:
        return resolve_conninfo(
            self.clone_database_url,
            host=self.clone_database_host,
            port=self.clone_database_port,
            dbname=self.clone_database_name,
            user=self.clone_database_user,
            password=self.clone_database_password,
            sslmode=self.clone_database_sslmode,
        )

    @field_validator(
        "clone_template_database",
        "clone_admin_role",
        "clone_runner_role",
    )
    @classmethod
    def identifiers_are_safe(cls, value: str) -> str:
        return _validated_identifier(value)

    @model_validator(mode="after")
    def admin_connection_is_not_the_template(self) -> CloneEvaluatorSettings:
        connection = conninfo_to_dict(self.clone_database_conninfo)
        if connection.get("dbname") == self.clone_template_database:
            raise ValueError("CLONE_DATABASE_URL appdb template'i yerine yonetim database'ini gostermeli")
        return self


@lru_cache
def get_clone_evaluator_settings() -> CloneEvaluatorSettings:
    return CloneEvaluatorSettings()


def _validated_identifier(value: str) -> str:
    if not value or value != value.strip() or "\x00" in value:
        raise ValueError("PostgreSQL identifier boslukla baslayamaz/bitemez ve NUL iceremez")
    if len(value.encode("utf-8")) > 63:
        raise ValueError("PostgreSQL identifier UTF-8 olarak en fazla 63 byte olabilir")
    return value


class ValidatedCloneIndexCandidate(BaseModel):
    candidateId: uuid.UUID
    plannerValidation: Literal["VALIDATED"]
    method: Literal["btree"]
    schemaName: str
    tableName: str
    columns: list[str] = Field(min_length=1, max_length=2)
    indexName: str
    createIndexSql: str = Field(min_length=1, max_length=4_000)

    @field_validator("schemaName", "tableName", "indexName")
    @classmethod
    def identifiers_are_safe(cls, value: str) -> str:
        return _validated_identifier(value)

    @field_validator("columns")
    @classmethod
    def columns_are_safe_and_unique(cls, values: list[str]) -> list[str]:
        checked = [_validated_identifier(value) for value in values]
        if len(set(checked)) != len(checked):
            raise ValueError("Index kolonlari tekrar edemez")
        return checked

    @model_validator(mode="after")
    def system_schemas_are_forbidden(self) -> ValidatedCloneIndexCandidate:
        if self.schemaName in {"pg_catalog", "information_schema"} or self.schemaName.startswith(
            "pg_toast"
        ):
            raise ValueError("Sistem semalarinda runtime index dogrulamasi yapilamaz")
        return self


class InternalCloneIndexEvaluationRequest(BaseModel):
    serverAlias: str = Field(min_length=1, max_length=120)
    databaseName: str = Field(min_length=1, max_length=63)
    queryId: str = Field(min_length=1, max_length=32, pattern=r"^-?\d+$")
    normalizedSql: str = Field(min_length=1, max_length=100_000)
    bindValues: list[str | int | float | bool | None] = Field(
        default_factory=list,
        max_length=16,
    )
    candidate: ValidatedCloneIndexCandidate

    @field_validator("bindValues")
    @classmethod
    def bind_values_are_small_json_scalars(
        cls,
        values: list[str | int | float | bool | None],
    ) -> list[str | int | float | bool | None]:
        for value in values:
            if type(value) not in {str, int, float, bool, type(None)}:
                raise ValueError("runtime bind values must be JSON scalars")
            if isinstance(value, str) and len(value) > 2_048:
                raise ValueError("runtime string bind value is too long")
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError("runtime numeric bind value must be finite")
        if len(json.dumps(values, ensure_ascii=False).encode("utf-8")) > 8_192:
            raise ValueError("runtime bind value payload is too large")
        return values


class RuntimePlanMetrics(BaseModel):
    medianExecutionTimeMs: float
    minExecutionTimeMs: float
    maxExecutionTimeMs: float
    medianPlanningTimeMs: float
    medianSharedHitBlocks: float
    medianSharedReadBlocks: float
    medianTempReadBlocks: float
    medianTempWrittenBlocks: float
    accessMethod: str | None = None


class RuntimeCloneValidation(BaseModel):
    mode: Literal["EXPLAIN_ANALYZE"] = "EXPLAIN_ANALYZE"
    statementClass: Literal["READ_ONLY_SELECT"] = "READ_ONLY_SELECT"
    planPreflight: Literal["READ_ONLY"] = "READ_ONLY"
    transactionReadOnly: Literal[True] = True
    runnerPolicyRevision: int = Field(ge=1)
    cacheProfile: Literal["ALTERNATING_WARM"] = "ALTERNATING_WARM"
    measuredRuns: int
    warmupRuns: int
    postgresVersion: str
    baseline: RuntimePlanMetrics
    candidate: RuntimePlanMetrics
    executionImprovementPercent: float
    candidateIndexUsed: bool
    indexBuildTimeMs: float
    actualIndexSizeBytes: int
    tableSizeBytes: int
    evaluatedAt: datetime


class CloneIndexEvaluationResult(BaseModel):
    status: Literal["RUNTIME_VALIDATED", "NO_RUNTIME_IMPROVEMENT", "UNAVAILABLE", "UNSAFE"]
    reasonCode: str
    message: str
    candidateId: uuid.UUID
    validation: RuntimeCloneValidation | None = None
    ddlTarget: Literal["DISPOSABLE_CLONE"] = "DISPOSABLE_CLONE"
    sourceDdlExecuted: Literal[False] = False
    cloneDdlExecuted: bool
    cloneDestroyed: bool


class CloneEvaluationStop(Exception):
    def __init__(self, result_status: str, reason_code: str, message: str):
        super().__init__(message)
        self.result_status = result_status
        self.reason_code = reason_code
        self.message = message


READ_ONLY_RUNNER_POLICY_REVISION = 1

_STATEMENT_COMMAND_TOKENS = {
    "SELECT",
    "INSERT",
    "UPDATE",
    "DELETE",
    "MERGE",
    "VALUES",
    "TABLE",
}
_NON_READ_TOKENS = {
    "INSERT",
    "UPDATE",
    "DELETE",
    "MERGE",
    "COPY",
    "CALL",
    "DO",
    "CREATE",
    "ALTER",
    "DROP",
    "TRUNCATE",
    "GRANT",
    "REVOKE",
    "COMMENT",
    "SECURITY",
    "VACUUM",
    "ANALYZE",
    "REFRESH",
    "REINDEX",
    "CLUSTER",
    # PostgreSQL SELECT INTO creates a table.  Plain EXPLAIN reports it as a
    # normal SELECT plan, so it must be rejected before any database call.
    "INTO",
}
_SIDE_EFFECT_ROUTINE_TOKENS = {
    "NEXTVAL",
    "SETVAL",
    "SET_CONFIG",
    "PG_NOTIFY",
    "PG_CANCEL_BACKEND",
    "PG_TERMINATE_BACKEND",
    "PG_RELOAD_CONF",
    "PG_ROTATE_LOGFILE",
    "PG_SWITCH_WAL",
    "PG_CREATE_RESTORE_POINT",
    "PG_LOGICAL_EMIT_MESSAGE",
    "PG_ADVISORY_LOCK",
    "PG_ADVISORY_LOCK_SHARED",
    "PG_ADVISORY_XACT_LOCK",
    "PG_ADVISORY_XACT_LOCK_SHARED",
    "PG_TRY_ADVISORY_LOCK",
    "PG_TRY_ADVISORY_LOCK_SHARED",
    "PG_TRY_ADVISORY_XACT_LOCK",
    "PG_TRY_ADVISORY_XACT_LOCK_SHARED",
    "PG_ADVISORY_UNLOCK",
    "PG_ADVISORY_UNLOCK_ALL",
    "PG_ADVISORY_UNLOCK_SHARED",
    "DBLINK_EXEC",
    "LO_CREATE",
    "LO_FROM_BYTEA",
    "LO_IMPORT",
    "LO_PUT",
    "LO_UNLINK",
    "LO_WRITE",
    "LOWRITE",
}
_ROW_LOCK_SUFFIXES = {
    ("UPDATE",),
    ("NO", "KEY", "UPDATE"),
    ("SHARE",),
    ("KEY", "SHARE"),
}


def _is_identifier_start(character: str) -> bool:
    return character == "_" or character.isalpha() or ord(character) >= 128


def _is_identifier_continuation(character: str) -> bool:
    return _is_identifier_start(character) or character.isdigit() or character == "$"


def _scan_replay_sql(query: str) -> tuple[str, list[tuple[str, int]], list[int]]:
    """Tokenize the security-relevant PostgreSQL surface without decoding values.

    Literals, quoted identifiers and nested comments are skipped, so words or
    semicolons inside data cannot change the policy decision.  Ambiguous or
    unterminated lexical constructs fail closed.  PostgreSQL still performs
    the authoritative parse during the non-ANALYZE plan preflight.
    """

    tokens: list[tuple[str, int]] = []
    parameter_numbers: list[int] = []
    semicolons: list[int] = []
    significant_positions: list[int] = []
    depth = 0
    index = 0
    length = len(query)

    while index < length:
        character = query[index]
        if character.isspace():
            index += 1
            continue

        if query.startswith("--", index):
            line_feed = query.find("\n", index + 2)
            carriage_return = query.find("\r", index + 2)
            line_endings = tuple(
                position
                for position in (line_feed, carriage_return)
                if position >= 0
            )
            if not line_endings:
                index = length
            else:
                index = min(line_endings) + 1
                if (
                    query[index - 1] == "\r"
                    and index < length
                    and query[index] == "\n"
                ):
                    index += 1
            continue

        if query.startswith("/*", index):
            comment_depth = 1
            index += 2
            while index < length and comment_depth:
                if query.startswith("/*", index):
                    comment_depth += 1
                    index += 2
                elif query.startswith("*/", index):
                    comment_depth -= 1
                    index += 2
                else:
                    index += 1
            if comment_depth:
                raise ValueError("unterminated block comment")
            continue

        if character in {"'", '"'}:
            delimiter = character
            escape_backslash = False
            if index >= 1 and character == "'":
                escape_backslash = query[index - 1] in {"e", "E"} and (
                    index < 2
                    or not _is_identifier_continuation(query[index - 2])
                )
            significant_positions.append(index)
            index += 1
            while index < length:
                if escape_backslash and query[index] == "\\":
                    index += 2
                    continue
                if query[index] != delimiter:
                    index += 1
                    continue
                if index + 1 < length and query[index + 1] == delimiter:
                    index += 2
                    continue
                significant_positions.append(index)
                index += 1
                break
            else:
                raise ValueError("unterminated quoted value")
            continue

        if character == "$":
            dollar_delimiter: str | None = None
            if query.startswith("$$", index):
                dollar_delimiter = "$$"
            elif index + 1 < length and _is_identifier_start(query[index + 1]):
                tag_end = index + 2
                # Dollar-quote tags follow unquoted identifier characters but
                # the closing '$' is the delimiter, not part of the tag.
                while tag_end < length and (
                    _is_identifier_start(query[tag_end])
                    or query[tag_end].isdigit()
                ):
                    tag_end += 1
                if tag_end < length and query[tag_end] == "$":
                    dollar_delimiter = query[index : tag_end + 1]

            if dollar_delimiter is not None:
                significant_positions.append(index)
                closing = query.find(dollar_delimiter, index + len(dollar_delimiter))
                if closing < 0:
                    raise ValueError("unterminated dollar-quoted value")
                index = closing + len(dollar_delimiter)
                significant_positions.append(index - 1)
                continue

            if index + 1 < length and query[index + 1].isdigit():
                parameter_end = index + 2
                while parameter_end < length and query[parameter_end].isdigit():
                    parameter_end += 1
                parameter_numbers.append(int(query[index + 1 : parameter_end]))
                significant_positions.append(parameter_end - 1)
                index = parameter_end
                continue

        if _is_identifier_start(character):
            token_end = index + 1
            while token_end < length and _is_identifier_continuation(query[token_end]):
                token_end += 1
            tokens.append((query[index:token_end].upper(), depth))
            significant_positions.append(token_end - 1)
            index = token_end
            continue

        if character == "(":
            significant_positions.append(index)
            depth += 1
            index += 1
            continue
        if character == ")":
            significant_positions.append(index)
            depth -= 1
            if depth < 0:
                raise ValueError("unbalanced closing parenthesis")
            index += 1
            continue
        if character == ";":
            semicolons.append(index)
            index += 1
            continue

        significant_positions.append(index)
        index += 1

    if depth:
        raise ValueError("unbalanced opening parenthesis")
    if len(semicolons) > 1:
        raise ValueError("multiple statement delimiters")
    if semicolons:
        terminator = semicolons[0]
        if any(position > terminator for position in significant_positions):
            raise ValueError("content after statement delimiter")
        query = query[:terminator].rstrip()
    return query, tokens, parameter_numbers


def _assert_read_only_select(
    normalized_sql: str,
) -> tuple[str, list[int]]:
    try:
        query, tokens_with_depth, parameter_numbers = _scan_replay_sql(
            normalized_sql.strip()
        )
    except ValueError as exc:
        raise CloneEvaluationStop(
            "UNSAFE",
            "MULTI_STATEMENT_OR_INVALID_SQL",
            "Yalniz tek ve gecerli bir salt-okunur SELECT sorgusu calistirilabilir.",
        ) from exc

    top_level_tokens = [token for token, depth in tokens_with_depth if depth == 0]
    if not query or not top_level_tokens:
        raise CloneEvaluationStop(
            "UNSAFE",
            "SELECT_ONLY",
            "Disposable clone dogrulamasi yalniz salt-okunur SELECT sorgularini calistirir.",
        )

    first_token = top_level_tokens[0]
    statement_command = first_token
    if first_token == "WITH":
        statement_command = next(
            (
                token
                for token in top_level_tokens[1:]
                if token in _STATEMENT_COMMAND_TOKENS
            ),
            "",
        )
    if statement_command != "SELECT":
        raise CloneEvaluationStop(
            "UNSAFE",
            "SELECT_ONLY",
            "Disposable clone dogrulamasi yalniz salt-okunur SELECT sorgularini calistirir.",
        )

    tokens = [token for token, _depth in tokens_with_depth]
    if any(token in _NON_READ_TOKENS for token in tokens) or any(
        token in _SIDE_EFFECT_ROUTINE_TOKENS for token in tokens
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "SELECT_ONLY",
            "Yazma, DDL, SELECT INTO veya yan etkili rutin iceren sorgular calistirilamaz.",
        )
    for position, token in enumerate(tokens):
        if token != "FOR":
            continue
        for suffix in _ROW_LOCK_SUFFIXES:
            if tuple(tokens[position + 1 : position + 1 + len(suffix)]) == suffix:
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "SELECT_ONLY",
                    "Satir kilidi alan SELECT sorgulari EXPLAIN ANALYZE kapsaminda degildir.",
                )

    return query, parameter_numbers


def _replay_query(
    normalized_sql: str,
    bind_values: list[str | int | float | bool | None] | None = None,
) -> tuple[str, tuple[str | int | float | bool | None, ...]]:
    """Return a narrow SELECT and operator-approved replay parameters.

    Values arrive only over the internal channel after an exact repository
    fixture lookup. They are never concatenated as raw SQL; psycopg's
    type-aware Literal adapter renders EXECUTE arguments only after the
    statement gate and PostgreSQL plan preflight have passed.
    """

    values = list(bind_values or [])
    if "\x00" in normalized_sql:
        raise CloneEvaluationStop(
            "UNSAFE",
            "MULTI_STATEMENT_OR_INVALID_SQL",
            "Yalniz tek bir SELECT sorgusu calistirilabilir.",
        )
    query, parameter_numbers = _assert_read_only_select(normalized_sql)
    if not parameter_numbers:
        if values:
            raise CloneEvaluationStop(
                "UNSAFE",
                "UNEXPECTED_REPLAY_VALUES",
                "Parametresiz sorgu icin replay fixture bind degeri tasiyor.",
            )
        return query, ()

    highest_parameter = max(parameter_numbers)
    if highest_parameter > 16 or set(parameter_numbers) != set(range(1, highest_parameter + 1)):
        raise CloneEvaluationStop(
            "UNSAFE",
            "INVALID_PARAMETER_LAYOUT",
            "Normalize sorgu parametreleri $1'den baslayan bitisik ve en fazla 16 deger olmali.",
        )
    if len(values) != highest_parameter:
        raise CloneEvaluationStop(
            "UNAVAILABLE",
            "REPLAY_FIXTURE_VALUE_COUNT_MISMATCH",
            "Onayli replay fixture normalize sorgunun bind parametre sayisiyla eslesmiyor.",
        )
    return query, tuple(values)


def _production_index_sql(candidate: ValidatedCloneIndexCandidate) -> str:
    columns = sql.SQL(", ").join(sql.Identifier(column) for column in candidate.columns)
    return (
        sql.SQL("CREATE INDEX CONCURRENTLY {} ON {}.{} USING btree ({});")
        .format(
            sql.Identifier(candidate.indexName),
            sql.Identifier(candidate.schemaName),
            sql.Identifier(candidate.tableName),
            columns,
        )
        .as_string(None)
    )


def _validated_request(
    payload: InternalCloneIndexEvaluationRequest,
    settings: CloneEvaluatorSettings,
) -> tuple[str, tuple[str | int | float | bool | None, ...]]:
    if payload.databaseName != settings.clone_template_database:
        raise CloneEvaluationStop(
            "UNAVAILABLE",
            "DATABASE_NOT_CONFIGURED",
            "Istek, yapilandirilmis disposable clone template database'i ile eslesmiyor.",
        )
    expected = _production_index_sql(payload.candidate)
    if payload.candidate.createIndexSql.strip() != expected:
        raise CloneEvaluationStop(
            "UNSAFE",
            "CANDIDATE_SQL_MISMATCH",
            "Aday SQL structured identifier'lardan yeniden uretilen guvenli SQL ile eslesmiyor.",
        )
    return _replay_query(payload.normalizedSql, payload.bindValues)


def _advice(
    payload: InternalCloneIndexEvaluationRequest,
    result_status: Literal["RUNTIME_VALIDATED", "NO_RUNTIME_IMPROVEMENT", "UNAVAILABLE", "UNSAFE"],
    reason_code: str,
    message: str,
    *,
    validation: dict[str, Any] | None = None,
    clone_ddl_executed: bool = False,
    clone_destroyed: bool = False,
) -> dict[str, Any]:
    return {
        "status": result_status,
        "reasonCode": reason_code,
        "message": message,
        "candidateId": payload.candidate.candidateId,
        "validation": validation,
        "ddlTarget": "DISPOSABLE_CLONE",
        "sourceDdlExecuted": False,
        "cloneDdlExecuted": clone_ddl_executed,
        "cloneDestroyed": clone_destroyed,
    }


def _connection_dsn(
    settings: CloneEvaluatorSettings,
    database_name: str,
    *,
    runner: bool = False,
) -> str:
    overrides: dict[str, object] = {
        "dbname": database_name,
        "connect_timeout": settings.clone_connect_timeout_seconds,
        "application_name": (
            "postgresql-advisor-clone-runner" if runner else "postgresql-advisor-clone-builder"
        ),
    }
    if runner:
        overrides.update(
            user=settings.clone_runner_role,
            password=settings.clone_runner_password,
        )
    return make_conninfo(settings.clone_database_conninfo, **overrides)


def _connect(
    settings: CloneEvaluatorSettings,
    database_name: str,
    *,
    runner: bool = False,
) -> psycopg.Connection[Any]:
    return psycopg.connect(
        _connection_dsn(settings, database_name, runner=runner),
        autocommit=True,
        row_factory=dict_row,
    )


def _guard_clone_connection(
    cursor: psycopg.Cursor[Any],
    settings: CloneEvaluatorSettings,
    *,
    expected_role: str,
) -> dict[str, Any]:
    cursor.execute(
        "SELECT current_setting('advisor.validation_clone', true) AS clone_marker, "
        "current_database() AS database_name, current_user AS role_name, "
        "current_setting('server_version') AS postgres_version"
    )
    row = cursor.fetchone()
    if not row or str(row["clone_marker"]).lower() != "on":
        raise CloneEvaluationStop(
            "UNSAFE",
            "CLONE_GUARD_MISSING",
            "DDL reddedildi: hedef PostgreSQL advisor.validation_clone=on isaretini tasimiyor.",
        )
    if row["role_name"] != expected_role:
        raise CloneEvaluationStop(
            "UNSAFE",
            "CLONE_ROLE_MISMATCH",
            "Clone baglantisi beklenen izole rolle kurulmamisti; islem reddedildi.",
        )
    return dict(row)


def _assert_clone_ready(settings: CloneEvaluatorSettings) -> dict[str, Any]:
    admin_database = conninfo_to_dict(settings.clone_database_conninfo).get("dbname") or "postgres"
    with _connect(settings, admin_database) as connection:
        with connection.cursor() as cursor:
            guard = _guard_clone_connection(
                cursor,
                settings,
                expected_role=settings.clone_admin_role,
            )
            cursor.execute(
                "SELECT datname, datallowconn, datistemplate "
                "FROM pg_database WHERE datname = %s",
                (settings.clone_template_database,),
            )
            template = cursor.fetchone()
            if (
                not template
                or not template["datallowconn"]
                or not template["datistemplate"]
            ):
                raise CloneEvaluationStop(
                    "UNAVAILABLE",
                    "CLONE_TEMPLATE_UNAVAILABLE",
                    "Disposable clone template database hazir veya template olarak isaretli degil.",
                )

    # The cluster-level marker alone is intentionally insufficient.  Require
    # the bootstrap manifest inside the exact template too, so pointing the
    # service at an ordinary database with a similarly named role fails closed.
    with _connect(settings, settings.clone_template_database) as connection:
        with connection.cursor() as cursor:
            _guard_clone_connection(
                cursor,
                settings,
                expected_role=settings.clone_admin_role,
            )
            cursor.execute(
                "SELECT archive_restored, source_ddl_executed, "
                "runner_policy_revision, dangerous_routines_revoked "
                "FROM advisor_clone_meta.template_manifest WHERE singleton"
            )
            manifest = cursor.fetchone()
            if (
                not manifest
                or manifest["source_ddl_executed"]
                or int(manifest["runner_policy_revision"] or 0)
                != READ_ONLY_RUNNER_POLICY_REVISION
                or not manifest["dangerous_routines_revoked"]
            ):
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "CLONE_TEMPLATE_MANIFEST_INVALID",
                    "Disposable clone template manifesti veya salt-okunur runner policy kaniti gecersiz.",
                )
            guard["archive_restored"] = bool(manifest["archive_restored"])
            guard["runner_policy_revision"] = int(
                manifest["runner_policy_revision"]
            )
    return guard


def _create_job_database(settings: CloneEvaluatorSettings, database_name: str) -> None:
    _validated_identifier(database_name)
    admin_database = conninfo_to_dict(settings.clone_database_conninfo).get("dbname") or "postgres"
    with _connect(settings, admin_database) as connection:
        with connection.cursor() as cursor:
            _guard_clone_connection(cursor, settings, expected_role=settings.clone_admin_role)
            cursor.execute("SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = %s) AS exists", (database_name,))
            if cursor.fetchone()["exists"]:
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "CLONE_DATABASE_COLLISION",
                    "Rastgele uretilen clone database adi zaten var; islem guvenle durduruldu.",
                )
            cursor.execute(
                sql.SQL("CREATE DATABASE {} WITH TEMPLATE {} OWNER {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(settings.clone_template_database),
                    sql.Identifier(settings.clone_admin_role),
                )
            )


def _grant_runner_connect(settings: CloneEvaluatorSettings, database_name: str) -> None:
    _validated_identifier(database_name)
    admin_database = conninfo_to_dict(settings.clone_database_conninfo).get("dbname") or "postgres"
    with _connect(settings, admin_database) as connection:
        with connection.cursor() as cursor:
            _guard_clone_connection(cursor, settings, expected_role=settings.clone_admin_role)
            cursor.execute(
                sql.SQL("REVOKE CONNECT, TEMPORARY ON DATABASE {} FROM PUBLIC").format(
                    sql.Identifier(database_name)
                )
            )
            cursor.execute(
                sql.SQL("REVOKE TEMPORARY ON DATABASE {} FROM {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(settings.clone_runner_role),
                )
            )
            cursor.execute(
                sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(
                    sql.Identifier(database_name),
                    sql.Identifier(settings.clone_runner_role),
                )
            )


def _leading_index_columns(cursor: psycopg.Cursor[Any], relation_id: int) -> list[dict[str, Any]]:
    cursor.execute(
        """
        SELECT index_class.relname AS index_name,
               ARRAY(
                   SELECT attribute.attname
                     FROM unnest(i.indkey::smallint[]) WITH ORDINALITY AS key(attnum, position)
                     JOIN pg_attribute attribute
                       ON attribute.attrelid = i.indrelid
                      AND attribute.attnum = key.attnum
                    WHERE key.position <= i.indnkeyatts
                    ORDER BY key.position
               ) AS key_columns
          FROM pg_index i
          JOIN pg_class index_class ON index_class.oid = i.indexrelid
          JOIN pg_am access_method ON access_method.oid = index_class.relam
         WHERE i.indrelid = %s
           AND i.indisvalid
           AND i.indisready
           AND i.indpred IS NULL
           AND i.indexprs IS NULL
           AND access_method.amname = 'btree'
        """,
        (relation_id,),
    )
    return [dict(row) for row in cursor.fetchall()]


def _create_candidate_index(
    settings: CloneEvaluatorSettings,
    database_name: str,
    candidate: ValidatedCloneIndexCandidate,
    ddl_state: dict[str, bool],
) -> dict[str, Any]:
    with _connect(settings, database_name) as connection:
        with connection.cursor() as cursor:
            guard = _guard_clone_connection(
                cursor,
                settings,
                expected_role=settings.clone_admin_role,
            )
            cursor.execute(
                """
                SELECT relation.oid::bigint AS relation_id,
                       relation.relkind,
                       relation.relrowsecurity,
                       pg_total_relation_size(relation.oid)::bigint AS table_size_bytes
                  FROM pg_class relation
                  JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
                 WHERE namespace.nspname = %s
                   AND relation.relname = %s
                """,
                (candidate.schemaName, candidate.tableName),
            )
            relation = cursor.fetchone()
            if not relation or relation["relkind"] not in {"r", "p"}:
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "CLONE_RELATION_MISMATCH",
                    "Aday tablo disposable clone katalogunda uygun bir base/partitioned tablo degil.",
                )
            if relation["relrowsecurity"]:
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "ROW_LEVEL_SECURITY_ACTIVE",
                    "RLS etkin tabloda farkli clone roluyla runtime karsilastirmasi yapilmaz.",
                )
            cursor.execute(
                """
                SELECT attname
                  FROM pg_attribute
                 WHERE attrelid = %s
                   AND attnum > 0
                   AND NOT attisdropped
                   AND attname = ANY(%s::text[])
                """,
                (relation["relation_id"], candidate.columns),
            )
            existing_columns = {str(row["attname"]) for row in cursor.fetchall()}
            if existing_columns != set(candidate.columns):
                raise CloneEvaluationStop(
                    "UNSAFE",
                    "CLONE_COLUMN_MISMATCH",
                    "Aday kolon kimlikleri disposable clone kataloguyla eslesmiyor.",
                )
            for existing_index in _leading_index_columns(cursor, int(relation["relation_id"])):
                if list(existing_index["key_columns"] or [])[: len(candidate.columns)] == candidate.columns:
                    raise CloneEvaluationStop(
                        "NO_RUNTIME_IMPROVEMENT",
                        "EQUIVALENT_INDEX_EXISTS_IN_CLONE",
                        f"{existing_index['index_name']} ayni kolon sirasi ile clone'da zaten var.",
                    )

            columns = sql.SQL(", ").join(sql.Identifier(column) for column in candidate.columns)
            clone_ddl = sql.SQL("CREATE INDEX {} ON {}.{} USING btree ({})").format(
                sql.Identifier(candidate.indexName),
                sql.Identifier(candidate.schemaName),
                sql.Identifier(candidate.tableName),
                columns,
            )
            started = perf_counter()
            cursor.execute(clone_ddl)
            ddl_state["executed"] = True
            index_build_ms = (perf_counter() - started) * 1000
            cursor.execute(
                """
                SELECT pg_relation_size(index_class.oid)::bigint AS index_size_bytes
                  FROM pg_class index_class
                  JOIN pg_namespace namespace ON namespace.oid = index_class.relnamespace
                 WHERE namespace.nspname = %s
                   AND index_class.relname = %s
                   AND index_class.relkind IN ('i', 'I')
                """,
                (candidate.schemaName, candidate.indexName),
            )
            index = cursor.fetchone()
            if not index:
                raise CloneEvaluationStop(
                    "UNAVAILABLE",
                    "CLONE_INDEX_NOT_VISIBLE",
                    "CREATE INDEX tamamlandi ancak clone katalogunda index dogrulanamadi.",
                )
            return {
                "indexBuildTimeMs": round(index_build_ms, 3),
                "actualIndexSizeBytes": int(index["index_size_bytes"] or 0),
                "tableSizeBytes": int(relation["table_size_bytes"] or 0),
                "postgresVersion": str(guard["postgres_version"]),
            }


def _walk_plan(node: dict[str, Any]):
    yield node
    for child in node.get("Plans") or []:
        yield from _walk_plan(child)


def _decode_explain_row(row: Mapping[str, Any] | tuple[Any, ...] | None) -> dict[str, Any]:
    if row is None:
        raise CloneEvaluationStop(
            "UNAVAILABLE",
            "EMPTY_RUNTIME_PLAN",
            "Clone PostgreSQL plan sonucu dondurmedi.",
        )
    if isinstance(row, Mapping):
        if not row:
            raise CloneEvaluationStop(
                "UNSAFE",
                "INVALID_RUNTIME_PLAN",
                "Clone PostgreSQL plan yapisi salt-okunur olarak dogrulanamadi.",
            )
        raw = next(iter(row.values()))
    else:
        if not row:
            raise CloneEvaluationStop(
                "UNSAFE",
                "INVALID_RUNTIME_PLAN",
                "Clone PostgreSQL plan yapisi salt-okunur olarak dogrulanamadi.",
            )
        raw = row[0]
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise CloneEvaluationStop(
                "UNSAFE",
                "INVALID_RUNTIME_PLAN",
                "Clone PostgreSQL plan sonucu guvenli JSON biciminde degil.",
            ) from exc
    if (
        not isinstance(raw, list)
        or len(raw) != 1
        or not isinstance(raw[0], dict)
        or not isinstance(raw[0].get("Plan"), dict)
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "INVALID_RUNTIME_PLAN",
            "Clone PostgreSQL plan yapisi salt-okunur olarak dogrulanamadi.",
        )
    return raw[0]


def _assert_read_only_plan(plan: dict[str, Any]) -> None:
    unsafe_node_types = {
        "ModifyTable",
        "LockRows",
        "Foreign Scan",
        "Custom Scan",
    }
    unsafe_operations = {"INSERT", "UPDATE", "DELETE", "MERGE"}
    for node in _walk_plan(plan["Plan"]):
        node_type = str(node.get("Node Type") or "")
        operation = str(node.get("Operation") or "").upper()
        if node_type in unsafe_node_types or operation in unsafe_operations:
            raise CloneEvaluationStop(
                "UNSAFE",
                "READ_ONLY_PLAN_REQUIRED",
                "PostgreSQL plan preflight'i yazma, satir kilidi veya izole olmayan plan dugumu tespit etti.",
            )


def _assert_runner_policy(row: Mapping[str, Any] | None) -> None:
    if not row:
        raise CloneEvaluationStop(
            "UNSAFE",
            "RUNNER_POLICY_MISMATCH",
            "Clone runner salt-okunur policy durumu okunamadi.",
        )
    search_path = str(row.get("search_path") or "").replace(" ", "")
    required_true = (
        "transaction_read_only",
        "default_read_only",
        "row_security",
        "statement_timeout_exact",
        "lock_timeout_exact",
        "transaction_timeout_exact",
        "idle_timeout_exact",
        "jit_disabled",
        "standard_strings",
        "role_can_login",
        "role_inherit",
        "role_connection_limit_exact",
        "read_all_data_membership_exact",
        "temp_revoked",
        "schema_create_revoked",
        "dangerous_routines_revoked",
        "foreign_server_usage_revoked",
    )
    if (
        any(str(row.get(key)).lower() not in {"true", "on", "t", "1"} for key in required_true)
        or any(
            bool(row.get(key))
            for key in (
                "role_superuser",
                "role_createdb",
                "role_createrole",
                "role_replication",
                "role_bypassrls",
            )
        )
        or search_path != "pg_catalog,public"
    ):
        raise CloneEvaluationStop(
            "UNSAFE",
            "RUNNER_POLICY_MISMATCH",
            "Clone runner aktif transaction, rol veya ACL policy'si salt-okunur degil.",
        )


def _begin_read_only_runner_transaction(
    cursor: psycopg.Cursor[Any],
    settings: CloneEvaluatorSettings,
) -> None:
    cursor.execute("BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED READ ONLY")
    for setting_name, setting_value in (
        ("statement_timeout", f"{settings.clone_statement_timeout_ms}ms"),
        ("lock_timeout", f"{settings.clone_lock_timeout_ms}ms"),
        ("transaction_timeout", f"{settings.clone_transaction_timeout_ms}ms"),
        (
            "idle_in_transaction_session_timeout",
            f"{settings.clone_transaction_timeout_ms}ms",
        ),
        ("row_security", "on"),
        ("jit", "off"),
        ("standard_conforming_strings", "on"),
    ):
        cursor.execute(
            sql.SQL("SET LOCAL {} = {}").format(
                sql.Identifier(setting_name),
                sql.Literal(setting_value),
            )
        )
    cursor.execute("SET LOCAL search_path = pg_catalog, public")
    cursor.execute(
        """
        SELECT current_setting('transaction_read_only') = 'on'
                   AS transaction_read_only,
               current_setting('default_transaction_read_only') = 'on'
                   AS default_read_only,
               current_setting('row_security') = 'on' AS row_security,
               extract(
                   epoch FROM current_setting('statement_timeout')::interval
               ) * 1000 = %s AS statement_timeout_exact,
               extract(
                   epoch FROM current_setting('lock_timeout')::interval
               ) * 1000 = %s AS lock_timeout_exact,
               extract(
                   epoch FROM current_setting('transaction_timeout')::interval
               ) * 1000 = %s AS transaction_timeout_exact,
               extract(
                   epoch FROM current_setting(
                       'idle_in_transaction_session_timeout'
                   )::interval
               ) * 1000 = %s AS idle_timeout_exact,
               current_setting('jit') = 'off' AS jit_disabled,
               current_setting('standard_conforming_strings') = 'on'
                   AS standard_strings,
               current_setting('search_path') AS search_path,
               role.rolcanlogin AS role_can_login,
               role.rolinherit AS role_inherit,
               role.rolconnlimit = 4 AS role_connection_limit_exact,
               role.rolsuper AS role_superuser,
               role.rolcreatedb AS role_createdb,
               role.rolcreaterole AS role_createrole,
               role.rolreplication AS role_replication,
               role.rolbypassrls AS role_bypassrls,
               (
                   SELECT count(*) = 1
                      AND coalesce(bool_and(
                              granted_role.rolname = 'pg_read_all_data'
                          AND membership.inherit_option
                          AND NOT membership.set_option
                          AND NOT membership.admin_option
                          AND NOT EXISTS (
                              SELECT 1
                                FROM pg_auth_members inherited_membership
                               WHERE inherited_membership.member =
                                     granted_role.oid
                          )
                      ), false)
                     FROM pg_auth_members membership
                     JOIN pg_roles granted_role
                       ON granted_role.oid = membership.roleid
                    WHERE membership.member = role.oid
               ) AS read_all_data_membership_exact,
               NOT has_database_privilege(
                   current_user, current_database(), 'TEMPORARY'
               ) AS temp_revoked,
               NOT EXISTS (
                   SELECT 1
                     FROM pg_namespace namespace
                    WHERE namespace.nspname NOT LIKE 'pg_temp_%%'
                      AND namespace.nspname NOT LIKE 'pg_toast_temp_%%'
                      AND has_schema_privilege(
                          current_user, namespace.oid, 'CREATE'
                      )
               ) AS schema_create_revoked,
               NOT EXISTS (
                   SELECT 1
                     FROM pg_proc routine
                     JOIN pg_namespace routine_namespace
                       ON routine_namespace.oid = routine.pronamespace
                     JOIN pg_language routine_language
                       ON routine_language.oid = routine.prolang
                    WHERE (
                              routine.provolatile = 'v'
                           OR routine.prosecdef
                           OR routine.prokind = 'p'
                           OR (
                                  routine_namespace.nspname NOT IN (
                                      'pg_catalog', 'information_schema'
                                  )
                              AND routine_language.lanname NOT IN (
                                      'sql', 'plpgsql'
                                  )
                              )
                          )
                      AND has_function_privilege(
                          current_user, routine.oid, 'EXECUTE'
                      )
               ) AS dangerous_routines_revoked,
               NOT EXISTS (
                   SELECT 1
                     FROM pg_foreign_server server
                    WHERE has_server_privilege(
                        current_user, server.oid, 'USAGE'
                    )
               ) AS foreign_server_usage_revoked
         FROM pg_roles role
         WHERE role.rolname = current_user
        """,
        (
            settings.clone_statement_timeout_ms,
            settings.clone_lock_timeout_ms,
            settings.clone_transaction_timeout_ms,
            settings.clone_transaction_timeout_ms,
        ),
    )
    _assert_runner_policy(cursor.fetchone())


def _runtime_statement(
    cursor: psycopg.Cursor[Any],
    query: str,
    bind_values: tuple[str | int | float | bool | None, ...],
) -> sql.Composable:
    if not bind_values:
        return sql.SQL(query)
    cursor.execute(
        sql.SQL("PREPARE advisor_runtime_replay AS ") + sql.SQL(query),
        prepare=True,
    )
    # EXPLAIN EXECUTE cannot accept extended-protocol bind placeholders in its
    # utility-command argument list. Literal applies connection-aware quoting
    # only after the exact fixture and statement policy checks have passed.
    arguments = sql.SQL(", ").join(sql.Literal(value) for value in bind_values)
    return sql.SQL("EXECUTE advisor_runtime_replay ({})").format(arguments)


def _plain_explain_preflight(
    cursor: psycopg.Cursor[Any],
    runtime_statement: sql.Composable,
) -> dict[str, Any]:
    cursor.execute(
        sql.SQL("EXPLAIN (ANALYZE FALSE, VERBOSE TRUE, FORMAT JSON) ")
        + runtime_statement,
        prepare=True,
    )
    plan = _decode_explain_row(cursor.fetchone())
    _assert_read_only_plan(plan)
    return plan


def _preflight_read_only_query(
    settings: CloneEvaluatorSettings,
    database_name: str,
    query: str,
    bind_values: tuple[str | int | float | bool | None, ...],
) -> None:
    with _connect(settings, database_name, runner=True) as connection:
        with connection.cursor() as cursor:
            _guard_clone_connection(
                cursor,
                settings,
                expected_role=settings.clone_runner_role,
            )
            try:
                _begin_read_only_runner_transaction(cursor, settings)
                runtime_statement = _runtime_statement(cursor, query, bind_values)
                _plain_explain_preflight(cursor, runtime_statement)
            finally:
                try:
                    cursor.execute("ROLLBACK")
                except psycopg.Error:
                    pass


def _access_method(plan: dict[str, Any], table_name: str) -> str | None:
    for node in _walk_plan(plan["Plan"]):
        if node.get("Relation Name") == table_name:
            return str(node.get("Node Type"))
    return None


def _uses_index(plan: dict[str, Any], index_name: str) -> bool:
    return any(str(node.get("Index Name") or "") == index_name for node in _walk_plan(plan["Plan"]))


def _explain_analyze_once(
    settings: CloneEvaluatorSettings,
    database_name: str,
    query: str,
    bind_values: tuple[str | int | float | bool | None, ...],
    table_name: str,
    candidate_index_name: str | None,
) -> dict[str, Any]:
    with _connect(settings, database_name, runner=True) as connection:
        with connection.cursor() as cursor:
            _guard_clone_connection(
                cursor,
                settings,
                expected_role=settings.clone_runner_role,
            )
            try:
                _begin_read_only_runner_transaction(cursor, settings)
                runtime_statement = _runtime_statement(cursor, query, bind_values)
                _plain_explain_preflight(cursor, runtime_statement)
                explain_prefix = sql.SQL(
                    "EXPLAIN (ANALYZE TRUE, BUFFERS TRUE, WAL TRUE, TIMING TRUE, "
                    "SUMMARY TRUE, FORMAT JSON) "
                )
                cursor.execute(
                    explain_prefix + runtime_statement,
                    prepare=True,
                )
                plan = _decode_explain_row(cursor.fetchone())
                _assert_read_only_plan(plan)
            finally:
                try:
                    cursor.execute("ROLLBACK")
                except psycopg.Error:
                    pass

    root = plan["Plan"]
    return {
        "executionTimeMs": float(plan.get("Execution Time") or 0),
        "planningTimeMs": float(plan.get("Planning Time") or 0),
        "sharedHitBlocks": int(root.get("Shared Hit Blocks") or 0),
        "sharedReadBlocks": int(root.get("Shared Read Blocks") or 0),
        "tempReadBlocks": int(root.get("Temp Read Blocks") or 0),
        "tempWrittenBlocks": int(root.get("Temp Written Blocks") or 0),
        "accessMethod": _access_method(plan, table_name),
        "candidateIndexUsed": bool(candidate_index_name and _uses_index(plan, candidate_index_name)),
    }


def _median(samples: list[dict[str, Any]], key: str) -> float:
    return round(float(statistics.median(float(sample[key]) for sample in samples)), 3)


def _most_common_access(samples: list[dict[str, Any]]) -> str | None:
    values = [str(sample["accessMethod"]) for sample in samples if sample.get("accessMethod")]
    return Counter(values).most_common(1)[0][0] if values else None


def _aggregate_plan_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    execution_times = [float(sample["executionTimeMs"]) for sample in samples]
    return {
        "medianExecutionTimeMs": _median(samples, "executionTimeMs"),
        "minExecutionTimeMs": round(min(execution_times), 3),
        "maxExecutionTimeMs": round(max(execution_times), 3),
        "medianPlanningTimeMs": _median(samples, "planningTimeMs"),
        "medianSharedHitBlocks": _median(samples, "sharedHitBlocks"),
        "medianSharedReadBlocks": _median(samples, "sharedReadBlocks"),
        "medianTempReadBlocks": _median(samples, "tempReadBlocks"),
        "medianTempWrittenBlocks": _median(samples, "tempWrittenBlocks"),
        "accessMethod": _most_common_access(samples),
    }


def _benchmark(
    settings: CloneEvaluatorSettings,
    baseline_database: str,
    candidate_database: str,
    query: str,
    bind_values: tuple[str | int | float | bool | None, ...],
    candidate: ValidatedCloneIndexCandidate,
    index_details: dict[str, Any],
) -> dict[str, Any]:
    for _ in range(settings.clone_warmup_runs):
        _explain_analyze_once(
            settings,
            baseline_database,
            query,
            bind_values,
            candidate.tableName,
            None,
        )
        _explain_analyze_once(
            settings,
            candidate_database,
            query,
            bind_values,
            candidate.tableName,
            candidate.indexName,
        )

    baseline_samples: list[dict[str, Any]] = []
    candidate_samples: list[dict[str, Any]] = []
    for run_number in range(settings.clone_measured_runs):
        order = ("baseline", "candidate") if run_number % 2 == 0 else ("candidate", "baseline")
        for target in order:
            if target == "baseline":
                baseline_samples.append(
                    _explain_analyze_once(
                        settings,
                        baseline_database,
                        query,
                        bind_values,
                        candidate.tableName,
                        None,
                    )
                )
            else:
                candidate_samples.append(
                    _explain_analyze_once(
                        settings,
                        candidate_database,
                        query,
                        bind_values,
                        candidate.tableName,
                        candidate.indexName,
                    )
                )

    baseline = _aggregate_plan_samples(baseline_samples)
    candidate_metrics = _aggregate_plan_samples(candidate_samples)
    baseline_ms = float(baseline["medianExecutionTimeMs"])
    candidate_ms = float(candidate_metrics["medianExecutionTimeMs"])
    improvement = max(0.0, (baseline_ms - candidate_ms) / baseline_ms * 100) if baseline_ms else 0.0
    return {
        "mode": "EXPLAIN_ANALYZE",
        "statementClass": "READ_ONLY_SELECT",
        "planPreflight": "READ_ONLY",
        "transactionReadOnly": True,
        "runnerPolicyRevision": READ_ONLY_RUNNER_POLICY_REVISION,
        "cacheProfile": "ALTERNATING_WARM",
        "measuredRuns": settings.clone_measured_runs,
        "warmupRuns": settings.clone_warmup_runs,
        "postgresVersion": index_details["postgresVersion"],
        "baseline": baseline,
        "candidate": candidate_metrics,
        "executionImprovementPercent": round(improvement, 2),
        "candidateIndexUsed": all(sample["candidateIndexUsed"] for sample in candidate_samples),
        "indexBuildTimeMs": index_details["indexBuildTimeMs"],
        "actualIndexSizeBytes": index_details["actualIndexSizeBytes"],
        "tableSizeBytes": index_details["tableSizeBytes"],
        "evaluatedAt": datetime.now(timezone.utc),
    }


def _destroy_job_databases(settings: CloneEvaluatorSettings, database_names: list[str]) -> bool:
    if not database_names:
        return True
    admin_database = conninfo_to_dict(settings.clone_database_conninfo).get("dbname") or "postgres"
    cleanup_ok = True
    for database_name in reversed(database_names):
        try:
            with _connect(settings, admin_database) as connection:
                with connection.cursor() as cursor:
                    _guard_clone_connection(
                        cursor,
                        settings,
                        expected_role=settings.clone_admin_role,
                    )
                    cursor.execute(
                        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                        "WHERE datname = %s AND pid <> pg_backend_pid()",
                        (database_name,),
                    )
                    cursor.execute(
                        sql.SQL("DROP DATABASE IF EXISTS {} WITH (FORCE)").format(
                            sql.Identifier(database_name)
                        )
                    )
        except Exception:
            cleanup_ok = False

    try:
        with _connect(settings, admin_database) as connection:
            with connection.cursor() as cursor:
                _guard_clone_connection(
                    cursor,
                    settings,
                    expected_role=settings.clone_admin_role,
                )
                cursor.execute(
                    "SELECT count(*) AS remaining FROM pg_database WHERE datname = ANY(%s::text[])",
                    (database_names,),
                )
                cleanup_ok = cleanup_ok and int(cursor.fetchone()["remaining"]) == 0
    except Exception:
        cleanup_ok = False
    return cleanup_ok


def _evaluate(payload: InternalCloneIndexEvaluationRequest) -> dict[str, Any]:
    settings = get_clone_evaluator_settings()
    created_databases: list[str] = []
    clone_ddl_executed = False
    ddl_state = {"executed": False}
    validation: dict[str, Any] | None = None
    result = _advice(
        payload,
        "UNAVAILABLE",
        "CLONE_EVALUATION_NOT_STARTED",
        "Disposable clone dogrulamasi baslatilamadi.",
    )

    try:
        query, bind_values = _validated_request(payload, settings)
        _assert_clone_ready(settings)
        job_suffix = uuid.uuid4().hex[:20]
        baseline_database = f"advisor_base_{job_suffix}"
        candidate_database = f"advisor_cand_{job_suffix}"

        _create_job_database(settings, baseline_database)
        created_databases.append(baseline_database)
        _grant_runner_connect(settings, baseline_database)

        # PostgreSQL performs the authoritative parse/plan under the exact
        # low-privilege runner policy before a candidate database or real index
        # is created.  EXPLAIN here deliberately omits ANALYZE.
        _preflight_read_only_query(
            settings,
            baseline_database,
            query,
            bind_values,
        )

        _create_job_database(settings, candidate_database)
        created_databases.append(candidate_database)
        _grant_runner_connect(settings, candidate_database)

        index_details = _create_candidate_index(
            settings,
            candidate_database,
            payload.candidate,
            ddl_state,
        )
        clone_ddl_executed = True
        validation = _benchmark(
            settings,
            baseline_database,
            candidate_database,
            query,
            bind_values,
            payload.candidate,
            index_details,
        )

        if not validation["candidateIndexUsed"]:
            result = _advice(
                payload,
                "NO_RUNTIME_IMPROVEMENT",
                "REAL_INDEX_NOT_USED",
                "Gercek index candidate clone planlarinin tamaminda kullanilmadi.",
                validation=validation,
                clone_ddl_executed=True,
            )
        elif validation["executionImprovementPercent"] < settings.clone_min_improvement_percent:
            result = _advice(
                payload,
                "NO_RUNTIME_IMPROVEMENT",
                "RUNTIME_THRESHOLD_NOT_MET",
                "Gercek index kullanildi ancak median calisma suresi iyilesme esigini asmadi.",
                validation=validation,
                clone_ddl_executed=True,
            )
        else:
            result = _advice(
                payload,
                "RUNTIME_VALIDATED",
                "RUNTIME_IMPROVEMENT_CONFIRMED",
                "Disposable clone gercek index ve EXPLAIN ANALYZE ile runtime iyilesmesini dogruladi.",
                validation=validation,
                clone_ddl_executed=True,
            )
    except CloneEvaluationStop as exc:
        result = _advice(
            payload,
            exc.result_status,  # type: ignore[arg-type]
            exc.reason_code,
            exc.message,
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    except psycopg.errors.ReadOnlySqlTransaction:
        result = _advice(
            payload,
            "UNSAFE",
            "READ_ONLY_TRANSACTION_VIOLATION",
            "Sorgu clone runner salt-okunur transaction policy'sini ihlal etti.",
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    except psycopg.errors.InsufficientPrivilege:
        result = _advice(
            payload,
            "UNSAFE",
            "READ_ONLY_POLICY_REJECTED",
            "Sorgu clone runner salt-okunur yetki policy'si tarafindan reddedildi.",
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    except psycopg.errors.QueryCanceled:
        result = _advice(
            payload,
            "UNAVAILABLE",
            "RUNTIME_QUERY_TIMEOUT",
            "EXPLAIN ANALYZE clone statement timeout sinirini asti.",
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    except psycopg.Error:
        result = _advice(
            payload,
            "UNAVAILABLE",
            "CLONE_DATABASE_ERROR",
            "Disposable clone database islemi basarisiz oldu; kaynakta DDL calistirilmadi.",
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    except Exception:
        result = _advice(
            payload,
            "UNAVAILABLE",
            "CLONE_EVALUATOR_ERROR",
            "Disposable clone evaluator beklenmeyen bir hata verdi.",
            validation=validation,
            clone_ddl_executed=clone_ddl_executed,
        )
    finally:
        try:
            clone_destroyed = _destroy_job_databases(settings, created_databases)
        except Exception:
            clone_destroyed = False

    clone_ddl_executed = clone_ddl_executed or ddl_state["executed"]
    result["cloneDdlExecuted"] = clone_ddl_executed
    result["cloneDestroyed"] = clone_destroyed
    if not clone_destroyed:
        result.update(
            status="UNAVAILABLE",
            reasonCode="CLONE_CLEANUP_FAILED",
            message="Clone database temizligi tamamlanamadi; operator temizligi gerekiyor.",
            sourceDdlExecuted=False,
            cloneDdlExecuted=clone_ddl_executed,
        )
    return result


def _authorized(token: str | None) -> None:
    expected = get_clone_evaluator_settings().clone_evaluator_token
    if not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Gecersiz clone evaluator tokeni.")


app = FastAPI(
    title="PostgreSQL Advisor Disposable Clone Evaluator",
    version="1.0.0-iteration-2.7",
    description="Internal, isolated real-index and EXPLAIN ANALYZE evaluator.",
)
_evaluation_slots = asyncio.Semaphore(1)


@app.get("/health")
async def health() -> dict[str, Any]:
    try:
        guard = await asyncio.to_thread(_assert_clone_ready, get_clone_evaluator_settings())
        return {
            "status": "healthy",
            "databaseName": guard["database_name"],
            "roleName": guard["role_name"],
            "postgresVersion": guard["postgres_version"],
            "validationClone": True,
            "readOnlySelectOnly": True,
            "runnerPolicyRevision": guard["runner_policy_revision"],
            "sourceDdlExecuted": False,
        }
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Disposable clone evaluator hazir degil.",
        ) from exc


@app.post(
    "/internal/v1/runtime-index-validations",
    response_model=CloneIndexEvaluationResult,
)
async def runtime_index_validation(
    payload: InternalCloneIndexEvaluationRequest,
    x_clone_evaluator_token: str | None = Header(default=None, alias="X-Clone-Evaluator-Token"),
) -> dict[str, Any]:
    _authorized(x_clone_evaluator_token)
    async with _evaluation_slots:
        return await asyncio.to_thread(_evaluate, payload)
