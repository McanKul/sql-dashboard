from __future__ import annotations

import asyncio
import threading
from types import SimpleNamespace
from typing import Any

import psycopg
from psycopg import sql
import pytest

import app.evaluator as evaluator_module
from app.schemas import InternalQueryExplainAnalyzeRequest, QueryExplainAnalyzeResult


def _request(**overrides: object) -> InternalQueryExplainAnalyzeRequest:
    values: dict[str, object] = {
        "serverId": 1,
        "serverAlias": "test-source",
        "databaseId": 16_384,
        "databaseName": "appdb",
        "queryId": "-42",
        "normalizedSql": "SELECT count(*) FROM public.orders",
        "bindValues": [],
    }
    values.update(overrides)
    return InternalQueryExplainAnalyzeRequest.model_validate(values)


def _settings() -> SimpleNamespace:
    return SimpleNamespace(
        evaluator_allowed_server_alias="test-source",
        evaluator_allowed_database="appdb",
        evaluator_database_user="advisor_evaluator",
        evaluator_database_conninfo="postgresql://advisor_evaluator@source-db/appdb",
        evaluator_runtime_statement_timeout_ms=120_000,
        evaluator_runtime_lock_timeout_ms=5_000,
        evaluator_runtime_transaction_timeout_ms=125_000,
    )


def _guard(**overrides: object) -> dict[str, object]:
    values: dict[str, object] = {
        "database_name": "appdb",
        "database_id": 16_384,
        "role_name": "advisor_evaluator",
        "session_role_name": "advisor_evaluator",
        "postgres_version": "18.4",
        "transaction_read_only": True,
        "default_read_only": True,
        "row_security": True,
        "statement_timeout_exact": True,
        "lock_timeout_exact": True,
        "transaction_timeout_exact": True,
        "role_can_login": True,
        "role_connection_limit_exact": True,
        "role_noinherit": True,
        "role_not_superuser": True,
        "role_not_createdb": True,
        "role_not_createrole": True,
        "role_not_replication": True,
        "role_not_bypassrls": True,
        "role_has_no_memberships": True,
        "database_create_revoked": True,
        "schema_create_revoked": True,
    }
    values.update(overrides)
    return values


def _plan(*, analyzed: bool) -> dict[str, object]:
    root: dict[str, object] = {
        "Node Type": "Aggregate",
        "Plan Rows": 1,
        "Actual Rows": 1,
        "Actual Loops": 1,
        "Shared Hit Blocks": 42 if analyzed else 0,
        "Shared Read Blocks": 3 if analyzed else 0,
        "Temp Read Blocks": 2 if analyzed else 0,
        "Temp Written Blocks": 1 if analyzed else 0,
        "WAL Records": 0,
        "WAL Bytes": 0,
        "Plans": [
            {
                "Node Type": "Seq Scan",
                "Relation Name": "orders",
                "Plan Rows": 100,
                "Actual Rows": 120 if analyzed else 0,
                "Actual Loops": 1,
            }
        ],
    }
    if analyzed:
        root.update({"Actual Startup Time": 0.1, "Actual Total Time": 4.1})
    return {
        "Plan": root,
        "Planning Time": 0.7 if analyzed else 0,
        "Execution Time": 4.3 if analyzed else 0,
    }


class _Cursor:
    def __init__(
        self,
        *,
        guard: dict[str, object] | None = None,
        fail_analyze: Exception | None = None,
    ) -> None:
        self.guard = guard or _guard()
        self.fail_analyze = fail_analyze
        self.next_result: object = None
        self.executed: list[str] = []

    def __enter__(self) -> "_Cursor":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def execute(
        self,
        statement: str | sql.Composable,
        params: object = None,
        **_: object,
    ) -> None:
        rendered = statement if isinstance(statement, str) else statement.as_string(None)
        self.executed.append(rendered)
        if "SELECT current_database() AS database_name" in rendered:
            self.next_result = self.guard
        elif "EXPLAIN (ANALYZE FALSE" in rendered:
            self.next_result = [[_plan(analyzed=False)]]
        elif "EXPLAIN (ANALYZE TRUE" in rendered:
            if self.fail_analyze is not None:
                raise self.fail_analyze
            self.next_result = [[_plan(analyzed=True)]]

    def fetchone(self) -> Any:
        return self.next_result


class _Connection:
    def __init__(
        self,
        cursor: _Cursor,
        *,
        rollback_fails: bool = False,
    ) -> None:
        self.test_cursor = cursor
        self.rollback_fails = rollback_fails
        self.rolled_back = False
        self.closed = False

    def cursor(self) -> _Cursor:
        return self.test_cursor

    def rollback(self) -> None:
        if self.rollback_fails:
            raise psycopg.OperationalError("rollback failed")
        self.rolled_back = True

    def close(self) -> None:
        self.closed = True


def _install_connection(
    monkeypatch: pytest.MonkeyPatch,
    connection: _Connection,
) -> None:
    monkeypatch.setattr(evaluator_module, "get_evaluator_settings", _settings)
    monkeypatch.setattr(
        evaluator_module.psycopg,
        "connect",
        lambda *_args, **_kwargs: connection,
    )


def test_source_plan_gate_allows_read_only_fdw_but_rejects_writes_and_locks() -> None:
    evaluator_module._assert_source_read_only_plan(
        {"Plan": {"Node Type": "Foreign Scan", "Operation": "SELECT"}}
    )

    for node in (
        {"Node Type": "ModifyTable", "Operation": "UPDATE"},
        {"Node Type": "LockRows"},
    ):
        with pytest.raises(evaluator_module.CloneEvaluationStop) as captured:
            evaluator_module._assert_source_read_only_plan({"Plan": node})
        assert captured.value.reason_code == "READ_ONLY_PLAN_REQUIRED"


def test_source_replay_supports_erp_sized_parameter_lists() -> None:
    query = "SELECT " + ", ".join(f"${index}" for index in range(1, 129))
    values = list(range(1, 129))

    replay, bound = evaluator_module._source_replay_query(query, values)

    assert replay == query
    assert bound == tuple(values)

    with pytest.raises(evaluator_module.CloneEvaluationStop) as captured:
        evaluator_module._source_replay_query("SELECT $129", [0] * 129)
    assert captured.value.reason_code == "INVALID_PARAMETER_LAYOUT"


def test_source_replay_restores_pgss_typed_literals_without_touching_data() -> None:
    query = (
        "SELECT interval $1, date $2, timestamp(3) with time zone $3, "
        "time without time zone $4, pg_catalog.timestamptz $5, "
        "'interval $6', $$ date $7 $$, $body$ time $8 $body$, \"interval $9\" "
        "/* timestamp $10 */ -- time $11\n"
    )

    replay, bound = evaluator_module._source_replay_query(
        query,
        ["1 day", "2026-07-26", "2026-07-26 12:00:00+03", "12:00:00", "2026-07-26 12:00:00+03"],
    )

    assert replay == (
        "SELECT $1::interval, $2::date, $3::timestamp(3) with time zone, "
        "$4::time without time zone, $5::pg_catalog.timestamptz, "
        "'interval $6', $$ date $7 $$, $body$ time $8 $body$, \"interval $9\" "
        "/* timestamp $10 */ -- time $11"
    )
    assert bound == (
        "1 day",
        "2026-07-26",
        "2026-07-26 12:00:00+03",
        "12:00:00",
        "2026-07-26 12:00:00+03",
    )


@pytest.mark.parametrize(
    ("type_sql", "expected_type"),
    [
        ("uuid", "uuid"),
        ("json", "json"),
        ("jsonb", "jsonb"),
        ("numeric(18, 4)", "numeric(18,4)"),
        ("decimal ( 10 , 2 )", "decimal(10,2)"),
        ("inet", "inet"),
        ("cidr", "cidr"),
        ("macaddr", "macaddr"),
        ("bit varying(32)", "bit varying(32)"),
        ("varbit ( 64 )", "varbit(64)"),
        ("bytea", "bytea"),
        ("character varying(80)", "character varying(80)"),
        ("double precision", "double precision"),
    ],
)
def test_source_replay_restores_common_pgss_builtin_typed_literals(
    type_sql: str,
    expected_type: str,
) -> None:
    replay, bound = evaluator_module._source_replay_query(
        f"SELECT {type_sql} $1",
        ["1"],
    )

    assert replay == f"SELECT $1::{expected_type}"
    assert bound == ("1",)


def test_source_explain_rejects_write_before_opening_a_database_connection(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(evaluator_module, "get_evaluator_settings", _settings)
    monkeypatch.setattr(
        evaluator_module.psycopg,
        "connect",
        lambda *_args, **_kwargs: pytest.fail("write must fail before connect"),
    )

    result = evaluator_module._evaluate_source_query(
        _request(normalizedSql="UPDATE public.orders SET status = 'paid'")
    )

    assert result["status"] == "UNSAFE"
    assert result["reasonCode"] == "SELECT_ONLY"
    assert result["sourceExecuted"] is False
    assert result["transactionRolledBack"] is False


@pytest.mark.parametrize(
    "statement",
    [
        'SELECT public."dblink_exec"($1, $2)',
        "SELECT * FROM public.dblink($1, $2) AS remote_result(value text)",
        "SELECT public.dblink_send_query($1, $2)",
        "SELECT public.dblink_connect($1, $2)",
        'SELECT public."dblink_cancel_query"($1)',
        'SELECT pg_catalog."pg_notify"($1, $2)',
        'SELECT pg_catalog."nextval"($1)',
    ],
)
def test_source_explain_rejects_quoted_side_effect_routines_before_connect(
    statement: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(evaluator_module, "get_evaluator_settings", _settings)
    monkeypatch.setattr(
        evaluator_module.psycopg,
        "connect",
        lambda *_args, **_kwargs: pytest.fail("side effect must fail before connect"),
    )

    result = evaluator_module._evaluate_source_query(
        _request(
            normalizedSql=statement,
            bindValues=["channel", "payload"][: statement.count("$")],
        )
    )

    assert result["status"] == "UNSAFE"
    assert result["reasonCode"] == "SELECT_ONLY"
    assert result["sourceExecuted"] is False


@pytest.mark.parametrize(
    "statement",
    [
        r'SELECT pg_catalog.U&"pg_n\006Ftify"($1, $2)',
        r'SELECT public.U&"dblink_\0065xec"($1, $2) UESCAPE \'!\'',
    ],
)
def test_source_explain_rejects_unicode_escaped_identifiers_before_connect(
    statement: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(evaluator_module, "get_evaluator_settings", _settings)
    monkeypatch.setattr(
        evaluator_module.psycopg,
        "connect",
        lambda *_args, **_kwargs: pytest.fail("unicode identifier must fail before connect"),
    )

    result = evaluator_module._evaluate_source_query(
        _request(normalizedSql=statement, bindValues=["channel", "payload"])
    )

    assert result["status"] == "UNSAFE"
    assert result["reasonCode"] == "MULTI_STATEMENT_OR_INVALID_SQL"
    assert result["sourceExecuted"] is False


def test_source_explain_runs_real_analyze_and_returns_json_plan(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = _Cursor()
    connection = _Connection(cursor)
    _install_connection(monkeypatch, connection)

    result = evaluator_module._evaluate_source_query(_request())
    validated = QueryExplainAnalyzeResult.model_validate(result)

    assert validated.status == "RUNTIME_VALIDATED"
    assert validated.executionTarget == "SOURCE_DATABASE"
    assert validated.sourceExecuted is True
    assert validated.sourceDdlExecuted is False
    assert validated.transactionRolledBack is True
    assert validated.validation is not None
    assert validated.validation.executionRole == "advisor_evaluator"
    assert validated.validation.databaseId == 16_384
    assert validated.validation.executionTimeMs == 4.3
    assert validated.validation.sharedHitBlocks == 42
    assert validated.validation.plan["Plan"]["Node Type"] == "Aggregate"
    assert any("EXPLAIN (ANALYZE FALSE" in statement for statement in cursor.executed)
    assert any("EXPLAIN (ANALYZE TRUE" in statement for statement in cursor.executed)
    assert connection.rolled_back is True
    assert connection.closed is True


def test_source_explain_fails_closed_on_stale_database_oid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _Connection(_Cursor(guard=_guard(database_id=99_999)))
    _install_connection(monkeypatch, connection)

    result = evaluator_module._evaluate_source_query(_request())

    assert result["status"] == "UNSAFE"
    assert result["reasonCode"] == "STALE_DATABASE_OID"
    assert result["sourceExecuted"] is False
    assert result["transactionRolledBack"] is True


def test_source_explain_reports_timeout_after_execution_started(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _Connection(
        _Cursor(fail_analyze=psycopg.errors.QueryCanceled("statement timeout"))
    )
    _install_connection(monkeypatch, connection)

    result = evaluator_module._evaluate_source_query(_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "SOURCE_QUERY_TIMEOUT"
    assert result["sourceExecuted"] is True
    assert result["transactionRolledBack"] is True


def test_source_explain_success_requires_confirmed_rollback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection = _Connection(_Cursor(), rollback_fails=True)
    _install_connection(monkeypatch, connection)

    result = evaluator_module._evaluate_source_query(_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "SOURCE_ROLLBACK_FAILED"
    assert result["sourceExecuted"] is True
    assert result["transactionRolledBack"] is False


@pytest.mark.asyncio
async def test_source_evaluator_rejects_requests_instead_of_queueing_them() -> None:
    original_slots = evaluator_module._evaluation_slots
    first_started = threading.Event()
    release_first = threading.Event()
    second_started = threading.Event()

    def worker(label: str) -> dict[str, Any]:
        if label == "first":
            first_started.set()
            release_first.wait(timeout=2)
        else:
            second_started.set()
        return {"label": label}

    evaluator_module._evaluation_slots = asyncio.Semaphore(1)
    try:
        first = asyncio.create_task(
            evaluator_module._run_serialized_evaluation(worker, "first")
        )
        assert await asyncio.to_thread(first_started.wait, 1)

        with pytest.raises(evaluator_module.EvaluationBusy):
            await evaluator_module._run_serialized_evaluation(worker, "second")
        assert second_started.is_set() is False

        release_first.set()
        assert await asyncio.wait_for(first, timeout=1) == {"label": "first"}
        assert await evaluator_module._run_serialized_evaluation(
            worker, "second"
        ) == {"label": "second"}
    finally:
        release_first.set()
        evaluator_module._evaluation_slots = original_slots
