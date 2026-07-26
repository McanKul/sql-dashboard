from __future__ import annotations

import asyncio
import threading
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock
from uuid import UUID

import psycopg
import pytest
from fastapi import HTTPException
from pydantic import ValidationError

import app.clone_evaluator as clone_module
from app.clone_evaluator import (
    CloneEvaluationStop,
    CloneEvaluatorSettings,
    CloneIndexEvaluationResult,
    CloneQueryEvaluationResult,
    InternalCloneIndexEvaluationRequest,
    InternalCloneQueryEvaluationRequest,
    ValidatedCloneIndexCandidate,
    _access_method,
    _aggregate_plan_samples,
    _assert_read_only_plan,
    _assert_runner_policy,
    _authorized,
    _begin_read_only_runner_transaction,
    _decode_explain_row,
    _evaluate,
    _evaluate_query,
    _guard_clone_connection,
    _production_index_sql,
    _plain_explain_preflight,
    _query_explain_validation,
    _replay_query,
    _runtime_statement,
    _scan_replay_sql,
    _uses_index,
    _validated_request,
    _validated_query_request,
)


_CANDIDATE_ID = UUID("65c9459a-4261-4a24-a880-b423e0469d6d")


def _candidate(**overrides: object) -> ValidatedCloneIndexCandidate:
    values: dict[str, object] = {
        "candidateId": _CANDIDATE_ID,
        "plannerValidation": "VALIDATED",
        "method": "btree",
        "schemaName": "public",
        "tableName": "orders",
        "columns": ["status"],
        "indexName": "idx_advisor_orders_status_65c9459a",
        "createIndexSql": "placeholder",
    }
    values.update(overrides)
    candidate = ValidatedCloneIndexCandidate.model_validate(values)
    if "createIndexSql" not in overrides:
        candidate = candidate.model_copy(
            update={"createIndexSql": _production_index_sql(candidate)}
        )
    return candidate


def _request(**overrides: object) -> InternalCloneIndexEvaluationRequest:
    values: dict[str, object] = {
        "serverAlias": "test-source",
        "databaseName": "appdb",
        "queryId": "-42",
        "normalizedSql": "SELECT count(*) FROM orders WHERE status = 'pending'",
        "candidate": _candidate(),
    }
    values.update(overrides)
    return InternalCloneIndexEvaluationRequest.model_validate(values)


def _query_request(**overrides: object) -> InternalCloneQueryEvaluationRequest:
    values: dict[str, object] = {
        "serverAlias": "test-source",
        "databaseName": "appdb",
        "queryId": "-42",
        "normalizedSql": "SELECT count(*) FROM orders WHERE status = 'pending'",
        "bindValues": [],
    }
    values.update(overrides)
    return InternalCloneQueryEvaluationRequest.model_validate(values)


def _settings(**overrides: object) -> CloneEvaluatorSettings:
    values: dict[str, object] = {
        "clone_database_url": (
            "postgresql://clone_admin:clone-admin-password@clone-db:5432/postgres"
        ),
        "clone_template_database": "appdb",
        "clone_admin_role": "clone_admin",
        "clone_runner_role": "clone_runner",
        "clone_runner_password": "clone-runner-password",
        "clone_evaluator_token": "clone-token",
        "clone_warmup_runs": 0,
        "clone_measured_runs": 3,
        "clone_min_improvement_percent": 10,
    }
    values.update(overrides)
    return CloneEvaluatorSettings.model_validate(values)


def _fake_job_database_creator(
    recorded: list[str] | None = None,
):
    def create(
        _settings: CloneEvaluatorSettings,
        database_name: str,
        tracked_databases: list[str],
    ) -> None:
        tracked_databases.append(database_name)
        if recorded is not None:
            recorded.append(database_name)

    return create


def _runtime_validation(
    *,
    improvement: float = 70.0,
    index_used: bool = True,
) -> dict[str, Any]:
    plan = {
        "medianExecutionTimeMs": 10.0,
        "minExecutionTimeMs": 9.0,
        "maxExecutionTimeMs": 11.0,
        "medianPlanningTimeMs": 0.2,
        "medianSharedHitBlocks": 10.0,
        "medianSharedReadBlocks": 0.0,
        "medianTempReadBlocks": 0.0,
        "medianTempWrittenBlocks": 0.0,
        "accessMethod": "Seq Scan",
    }
    return {
        "mode": "EXPLAIN_ANALYZE",
        "statementClass": "READ_ONLY_SELECT",
        "planPreflight": "READ_ONLY",
        "transactionReadOnly": True,
        "runnerPolicyRevision": 1,
        "cacheProfile": "ALTERNATING_WARM",
        "measuredRuns": 3,
        "warmupRuns": 0,
        "postgresVersion": "18.4",
        "baseline": plan,
        "candidate": {
            **plan,
            "medianExecutionTimeMs": 3.0,
            "minExecutionTimeMs": 2.8,
            "maxExecutionTimeMs": 3.2,
            "accessMethod": "Index Only Scan",
        },
        "executionImprovementPercent": improvement,
        "candidateIndexUsed": index_used,
        "indexBuildTimeMs": 12.5,
        "actualIndexSizeBytes": 131_072,
        "tableSizeBytes": 2_097_152,
        "evaluatedAt": "2026-07-25T12:00:00Z",
    }


def _query_validation(**overrides: object) -> dict[str, Any]:
    values: dict[str, object] = {
        "mode": "EXPLAIN_ANALYZE",
        "statementClass": "READ_ONLY_SELECT",
        "planPreflight": "READ_ONLY",
        "transactionReadOnly": True,
        "runnerPolicyRevision": 1,
        "postgresVersion": "18.4",
        "executionTimeMs": 11.2,
        "planningTimeMs": 0.4,
        "sharedHitBlocks": 25,
        "sharedReadBlocks": 2,
        "tempReadBlocks": 1,
        "tempWrittenBlocks": 1,
        "walRecords": 0,
        "walBytes": 0,
        "plan": {
            "Plan": {"Node Type": "Aggregate"},
            "Planning Time": 0.4,
            "Execution Time": 11.2,
        },
        "evaluatedAt": "2026-07-26T12:00:00Z",
    }
    values.update(overrides)
    return values


def test_read_only_select_is_the_only_runtime_replay_scope() -> None:
    assert _replay_query("  SELECT count(*) FROM orders;  ") == (
        "SELECT count(*) FROM orders",
        (),
    )
    query, values = _replay_query(
        "WITH recent AS (SELECT * FROM orders) SELECT count(*) FROM recent"
    )
    assert query.startswith("WITH recent")
    assert values == ()

    literal_query = (
        "/* DELETE is data here */ SELECT 'UPDATE; DROP' AS note, "
        "$$INSERT; CALL$$ AS body; -- trailing comment"
    )
    assert _replay_query(literal_query) == (
        literal_query.split("; --", 1)[0],
        (),
    )


def test_sql_scanner_only_counts_real_parameters_and_delimiters() -> None:
    query, tokens, parameters = _scan_replay_sql(
        "SELECT '$1; DELETE', $$ $2; UPDATE $$, value FROM orders "
        "WHERE status = $1 /* $3; DROP */; -- harmless"
    )

    assert query.endswith("WHERE status = $1 /* $3; DROP */")
    assert parameters == [1]
    assert ("DELETE", 0) not in tokens
    assert ("UPDATE", 0) not in tokens

    escaped_query = r'''SELECT E'quote\\\'; $9 DELETE', U&"name\0021" FROM orders'''
    scanned, escaped_tokens, escaped_parameters = _scan_replay_sql(escaped_query)
    assert scanned == escaped_query
    assert escaped_parameters == []
    assert ("DELETE", 0) not in escaped_tokens


def test_parameterized_replay_requires_exact_approved_scalar_fixture() -> None:
    query = "SELECT count(*) FROM orders WHERE status = $1 AND customer_id > $2"
    assert _replay_query(query, ["paid", 10]) == (query, ("paid", 10))

    for values in ([], ["paid"], ["paid", 10, True]):
        with pytest.raises(CloneEvaluationStop) as captured:
            _replay_query(query, values)
        assert captured.value.reason_code == "REPLAY_FIXTURE_VALUE_COUNT_MISMATCH"

    with pytest.raises(CloneEvaluationStop) as captured:
        _replay_query("SELECT count(*) FROM orders", ["paid"])
    assert captured.value.reason_code == "UNEXPECTED_REPLAY_VALUES"

    with pytest.raises(CloneEvaluationStop) as captured:
        _replay_query("SELECT * FROM orders WHERE status = $2", ["unused", "paid"])
    assert captured.value.reason_code == "INVALID_PARAMETER_LAYOUT"


@pytest.mark.parametrize(
    ("query", "reason_code"),
    [
        ("SELECT 1; SELECT 2", "MULTI_STATEMENT_OR_INVALID_SQL"),
        ("UPDATE orders SET status = 'paid'", "SELECT_ONLY"),
        ("WITH changed AS (DELETE FROM orders RETURNING *) SELECT * FROM changed", "SELECT_ONLY"),
        ("SELECT * FROM orders FOR UPDATE", "SELECT_ONLY"),
        ("SELECT * FROM orders FOR NO KEY UPDATE", "SELECT_ONLY"),
        ("SELECT * FROM orders FOR SHARE", "SELECT_ONLY"),
        ("SELECT * FROM orders FOR KEY SHARE SKIP LOCKED", "SELECT_ONLY"),
        ("SELECT status INTO TEMP replay_copy FROM orders", "SELECT_ONLY"),
        ("WITH recent AS (SELECT * FROM orders) TABLE recent", "SELECT_ONLY"),
        ("SELECT pg_catalog.pg_notify('channel', 'payload')", "SELECT_ONLY"),
        ("SELECT pg_advisory_lock(42)", "SELECT_ONLY"),
        ("SELECT 1 -- comment\r, pg_notify('channel', 'payload')", "SELECT_ONLY"),
        (
            r"SELECT U&'safe\' UESCAPE '!', pg_notify('channel', 'payload')",
            "SELECT_ONLY",
        ),
        ("SELECT '\x00'", "MULTI_STATEMENT_OR_INVALID_SQL"),
        ("SELECT 'unterminated", "MULTI_STATEMENT_OR_INVALID_SQL"),
        ("SELECT 1 /* unterminated", "MULTI_STATEMENT_OR_INVALID_SQL"),
        ("SELECT $tag$unterminated", "MULTI_STATEMENT_OR_INVALID_SQL"),
    ],
)
def test_runtime_replay_rejects_parameters_multiple_statements_and_writes(
    query: str,
    reason_code: str,
) -> None:
    with pytest.raises(CloneEvaluationStop) as captured:
        _replay_query(query)

    assert captured.value.result_status == "UNSAFE"
    assert captured.value.reason_code == reason_code


def test_plan_preflight_accepts_only_well_formed_read_plans() -> None:
    safe = {
        "Plan": {
            "Node Type": "Aggregate",
            "Plans": [{"Node Type": "Seq Scan", "Relation Name": "orders"}],
        }
    }
    _assert_read_only_plan(safe)
    assert _decode_explain_row(({"QUERY PLAN": [safe]})) == safe

    unsafe_plans = (
        {"Plan": {"Node Type": "ModifyTable", "Operation": "Insert"}},
        {
            "Plan": {
                "Node Type": "CTE Scan",
                "Plans": [{"Node Type": "ModifyTable", "Operation": "Delete"}],
            }
        },
        {
            "Plan": {
                "Node Type": "Limit",
                "Plans": [{"Node Type": "LockRows"}],
            }
        },
        {"Plan": {"Node Type": "Foreign Scan", "Relation Name": "remote_orders"}},
        {"Plan": {"Node Type": "Custom Scan", "Custom Plan Provider": "extension"}},
    )
    for plan in unsafe_plans:
        with pytest.raises(CloneEvaluationStop) as captured:
            _assert_read_only_plan(plan)
        assert captured.value.reason_code == "READ_ONLY_PLAN_REQUIRED"

    for malformed in (None, {}, {"QUERY PLAN": []}, {"QUERY PLAN": [{}]}):
        with pytest.raises(CloneEvaluationStop) as captured:
            _decode_explain_row(malformed)  # type: ignore[arg-type]
        assert captured.value.reason_code in {
            "EMPTY_RUNTIME_PLAN",
            "INVALID_RUNTIME_PLAN",
        }


def test_runner_policy_requires_active_read_only_acl_attestation() -> None:
    healthy = {
        "transaction_read_only": True,
        "default_read_only": True,
        "row_security": True,
        "statement_timeout_exact": True,
        "lock_timeout_exact": True,
        "transaction_timeout_exact": True,
        "idle_timeout_exact": True,
        "jit_disabled": True,
        "standard_strings": True,
        "search_path": "pg_catalog, public",
        "role_can_login": True,
        "role_inherit": True,
        "role_connection_limit_exact": True,
        "role_superuser": False,
        "role_createdb": False,
        "role_createrole": False,
        "role_replication": False,
        "role_bypassrls": False,
        "read_all_data_membership_exact": True,
        "temp_revoked": True,
        "schema_create_revoked": True,
        "dangerous_routines_revoked": True,
        "foreign_server_usage_revoked": True,
    }
    _assert_runner_policy(healthy)

    for key in (
        "transaction_read_only",
        "default_read_only",
        "read_all_data_membership_exact",
        "temp_revoked",
        "schema_create_revoked",
        "dangerous_routines_revoked",
        "foreign_server_usage_revoked",
    ):
        with pytest.raises(CloneEvaluationStop) as captured:
            _assert_runner_policy({**healthy, key: False})
        assert captured.value.reason_code == "RUNNER_POLICY_MISMATCH"

    with pytest.raises(CloneEvaluationStop):
        _assert_runner_policy({**healthy, "role_superuser": True})


class _RecordingCursor:
    def __init__(self, rows: list[dict[str, Any]]):
        self.rows = rows
        self.executions: list[tuple[object, bool]] = []

    def execute(
        self,
        statement: object,
        _parameters: object = None,
        *,
        prepare: bool = False,
    ) -> None:
        self.executions.append((statement, prepare))

    def fetchone(self) -> dict[str, Any]:
        return self.rows.pop(0)


def test_runner_transaction_is_attested_and_runtime_sql_forces_prepare() -> None:
    policy_row = {
        "transaction_read_only": True,
        "default_read_only": True,
        "row_security": True,
        "statement_timeout_exact": True,
        "lock_timeout_exact": True,
        "transaction_timeout_exact": True,
        "idle_timeout_exact": True,
        "jit_disabled": True,
        "standard_strings": True,
        "search_path": "pg_catalog, public",
        "role_can_login": True,
        "role_inherit": True,
        "role_connection_limit_exact": True,
        "role_superuser": False,
        "role_createdb": False,
        "role_createrole": False,
        "role_replication": False,
        "role_bypassrls": False,
        "read_all_data_membership_exact": True,
        "temp_revoked": True,
        "schema_create_revoked": True,
        "dangerous_routines_revoked": True,
        "foreign_server_usage_revoked": True,
    }
    safe_plan = {"Plan": {"Node Type": "Seq Scan", "Relation Name": "orders"}}
    cursor = _RecordingCursor([policy_row, {"QUERY PLAN": [safe_plan]}])

    _begin_read_only_runner_transaction(cursor, _settings())  # type: ignore[arg-type]
    runtime_statement = _runtime_statement(
        cursor,  # type: ignore[arg-type]
        "SELECT * FROM orders WHERE status = $1",
        ("paid",),
    )
    _plain_explain_preflight(cursor, runtime_statement)  # type: ignore[arg-type]

    assert "BEGIN TRANSACTION" in str(cursor.executions[0][0])
    # Both statements containing replay-derived SQL are forced through the
    # extended/prepared protocol, independently of the lexical gate.
    assert cursor.executions[-2][1] is True
    assert cursor.executions[-1][1] is True


def test_read_only_explain_analyze_preflights_executes_and_rolls_back(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    policy_row = {
        "transaction_read_only": True,
        "default_read_only": True,
        "row_security": True,
        "statement_timeout_exact": True,
        "lock_timeout_exact": True,
        "transaction_timeout_exact": True,
        "idle_timeout_exact": True,
        "jit_disabled": True,
        "standard_strings": True,
        "search_path": "pg_catalog, public",
        "role_can_login": True,
        "role_inherit": True,
        "role_connection_limit_exact": True,
        "role_superuser": False,
        "role_createdb": False,
        "role_createrole": False,
        "role_replication": False,
        "role_bypassrls": False,
        "read_all_data_membership_exact": True,
        "temp_revoked": True,
        "schema_create_revoked": True,
        "dangerous_routines_revoked": True,
        "foreign_server_usage_revoked": True,
    }
    plain_plan = {"Plan": {"Node Type": "Seq Scan"}}
    analyzed_plan = {
        "Plan": {"Node Type": "Seq Scan", "Shared Hit Blocks": 4},
        "Planning Time": 0.2,
        "Execution Time": 3.5,
    }
    cursor = MagicMock()
    cursor.fetchone.side_effect = [
        {
            "clone_marker": "on",
            "database_name": "advisor_query_abc",
            "role_name": "clone_runner",
            "postgres_version": "18.4",
        },
        policy_row,
        {"QUERY PLAN": [plain_plan]},
        {"QUERY PLAN": [analyzed_plan]},
    ]
    connection = MagicMock()
    connection.__enter__.return_value = connection
    connection.cursor.return_value.__enter__.return_value = cursor
    monkeypatch.setattr(clone_module, "_connect", lambda *_args, **_kwargs: connection)

    plan, postgres_version = clone_module._read_only_explain_analyze(
        _settings(),
        "advisor_query_abc",
        "SELECT * FROM orders",
        (),
    )

    assert plan == analyzed_plan
    assert postgres_version == "18.4"
    executed = [str(call.args[0]) for call in cursor.execute.call_args_list]
    assert any("ANALYZE FALSE" in statement for statement in executed)
    assert any("ANALYZE TRUE" in statement for statement in executed)
    assert executed[-1] == "ROLLBACK"


def test_candidate_sql_must_exactly_match_safely_quoted_identifiers() -> None:
    unsafe_looking = _candidate(
        schemaName='pub"lic',
        tableName='orders"; DROP TABLE secrets; --',
        columns=['sta"tus'],
        indexName='idx"; DROP DATABASE postgres; --',
    )
    generated = _production_index_sql(unsafe_looking)

    assert 'ON "pub""lic"."orders""; DROP TABLE secrets; --"' in generated
    assert 'USING btree ("sta""tus")' in generated
    assert generated.startswith('CREATE INDEX CONCURRENTLY "idx""; DROP DATABASE')

    accepted = unsafe_looking.model_copy(update={"createIndexSql": generated})
    payload = _request(candidate=accepted)
    assert _validated_request(payload, _settings()) == (payload.normalizedSql, ())

    mismatched = accepted.model_copy(
        update={"createIndexSql": generated + " DROP TABLE public.orders;"}
    )
    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_request(_request(candidate=mismatched), _settings())
    assert captured.value.reason_code == "CANDIDATE_SQL_MISMATCH"


def test_clone_candidate_scope_is_limited_to_two_columns() -> None:
    assert _candidate(columns=["customer_id", "status"]).columns == [
        "customer_id",
        "status",
    ]
    with pytest.raises(ValidationError):
        _candidate(columns=["customer_id", "status", "created_at"])


def test_request_database_must_match_configured_clone_template() -> None:
    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_request(_request(databaseName="production"), _settings())

    assert captured.value.result_status == "UNAVAILABLE"
    assert captured.value.reason_code == "DATABASE_NOT_CONFIGURED"


def test_request_source_must_match_configured_clone_template() -> None:
    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_request(_request(serverAlias="other-source"), _settings())

    assert captured.value.result_status == "UNAVAILABLE"
    assert captured.value.reason_code == "SOURCE_NOT_CONFIGURED"

    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_query_request(
            _query_request(serverAlias="other-source"),
            _settings(),
        )

    assert captured.value.result_status == "UNAVAILABLE"
    assert captured.value.reason_code == "SOURCE_NOT_CONFIGURED"


def test_direct_query_request_reuses_database_and_read_only_replay_guards() -> None:
    payload = _query_request(
        normalizedSql="SELECT * FROM orders WHERE status = $1",
        bindValues=["paid"],
    )
    assert _validated_query_request(payload, _settings()) == (
        payload.normalizedSql,
        ("paid",),
    )

    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_query_request(
            _query_request(databaseName="production"),
            _settings(),
        )
    assert captured.value.result_status == "UNAVAILABLE"
    assert captured.value.reason_code == "DATABASE_NOT_CONFIGURED"

    with pytest.raises(CloneEvaluationStop) as captured:
        _validated_query_request(
            _query_request(normalizedSql="DELETE FROM orders"),
            _settings(),
        )
    assert captured.value.result_status == "UNSAFE"
    assert captured.value.reason_code == "SELECT_ONLY"


def test_direct_query_bind_fixture_limits_match_index_validation() -> None:
    assert _query_request(bindValues=[None, True, 7, 2.5, "paid"]).bindValues == [
        None,
        True,
        7,
        2.5,
        "paid",
    ]
    for invalid_values in (
        [float("inf")],
        ["x" * 2_049],
        list(range(17)),
    ):
        with pytest.raises(ValidationError):
            _query_request(bindValues=invalid_values)


class _GuardCursor:
    def __init__(self, row: dict[str, object]):
        self.row = row
        self.executed = ""

    def execute(self, statement: str) -> None:
        self.executed = statement

    def fetchone(self) -> dict[str, object]:
        return self.row


def test_clone_guard_requires_marker_and_exact_role() -> None:
    healthy = _GuardCursor(
        {
            "clone_marker": "on",
            "database_name": "postgres",
            "role_name": "clone_admin",
            "postgres_version": "18.4",
        }
    )
    result = _guard_clone_connection(
        healthy,  # type: ignore[arg-type]
        _settings(),
        expected_role="clone_admin",
    )
    assert result["clone_marker"] == "on"
    assert "advisor.validation_clone" in healthy.executed

    for row, reason in (
        (
            {
                "clone_marker": None,
                "database_name": "appdb",
                "role_name": "clone_admin",
                "postgres_version": "18.4",
            },
            "CLONE_GUARD_MISSING",
        ),
        (
            {
                "clone_marker": "on",
                "database_name": "appdb",
                "role_name": "postgres",
                "postgres_version": "18.4",
            },
            "CLONE_ROLE_MISMATCH",
        ),
    ):
        with pytest.raises(CloneEvaluationStop) as captured:
            _guard_clone_connection(
                _GuardCursor(row),  # type: ignore[arg-type]
                _settings(),
                expected_role="clone_admin",
            )
        assert captured.value.reason_code == reason


def test_plan_helpers_find_real_index_and_aggregate_repeated_runs() -> None:
    plan = {
        "Plan": {
            "Node Type": "Aggregate",
            "Plans": [
                {
                    "Node Type": "Index Only Scan",
                    "Relation Name": "orders",
                    "Index Name": "idx_advisor_orders_status_65c9459a",
                }
            ],
        }
    }
    assert _access_method(plan, "orders") == "Index Only Scan"
    assert _uses_index(plan, "idx_advisor_orders_status_65c9459a") is True
    assert _uses_index(plan, "another_index") is False

    aggregate = _aggregate_plan_samples(
        [
            {
                "executionTimeMs": 12.0,
                "planningTimeMs": 0.3,
                "sharedHitBlocks": 8,
                "sharedReadBlocks": 2,
                "tempReadBlocks": 0,
                "tempWrittenBlocks": 0,
                "accessMethod": "Seq Scan",
            },
            {
                "executionTimeMs": 10.0,
                "planningTimeMs": 0.2,
                "sharedHitBlocks": 10,
                "sharedReadBlocks": 0,
                "tempReadBlocks": 0,
                "tempWrittenBlocks": 0,
                "accessMethod": "Seq Scan",
            },
            {
                "executionTimeMs": 11.0,
                "planningTimeMs": 0.4,
                "sharedHitBlocks": 9,
                "sharedReadBlocks": 1,
                "tempReadBlocks": 0,
                "tempWrittenBlocks": 0,
                "accessMethod": "Seq Scan",
            },
        ]
    )
    assert aggregate["medianExecutionTimeMs"] == 11.0
    assert aggregate["minExecutionTimeMs"] == 10.0
    assert aggregate["maxExecutionTimeMs"] == 12.0
    assert aggregate["medianSharedHitBlocks"] == 9.0
    assert aggregate["accessMethod"] == "Seq Scan"


def test_direct_query_validation_exposes_complete_raw_plan_metrics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    raw_plan = {
        "Plan": {
            "Node Type": "Hash Join",
            "Shared Hit Blocks": 120,
            "Shared Read Blocks": 8,
            "Temp Read Blocks": 3,
            "Temp Written Blocks": 4,
            "WAL Records": 0,
            "WAL Bytes": 0,
        },
        "Planning Time": 1.25,
        "Execution Time": 19.75,
    }
    monkeypatch.setattr(
        clone_module,
        "_read_only_explain_analyze",
        lambda *_args: (raw_plan, "18.4"),
    )

    validation = _query_explain_validation(
        _settings(),
        "advisor_query_abc",
        "SELECT * FROM orders",
        (),
    )

    assert validation["statementClass"] == "READ_ONLY_SELECT"
    assert validation["planPreflight"] == "READ_ONLY"
    assert validation["transactionReadOnly"] is True
    assert validation["runnerPolicyRevision"] == 1
    assert validation["postgresVersion"] == "18.4"
    assert validation["executionTimeMs"] == 19.75
    assert validation["planningTimeMs"] == 1.25
    assert validation["sharedHitBlocks"] == 120
    assert validation["sharedReadBlocks"] == 8
    assert validation["tempReadBlocks"] == 3
    assert validation["tempWrittenBlocks"] == 4
    assert validation["walRecords"] == 0
    assert validation["walBytes"] == 0
    assert validation["plan"] is raw_plan


def test_job_database_is_tracked_before_an_ambiguous_create_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = MagicMock()
    cursor.fetchone.return_value = {"exists": False}
    cursor.execute.side_effect = [None, psycopg.OperationalError("connection lost")]
    connection = MagicMock()
    connection.__enter__.return_value = connection
    connection.cursor.return_value.__enter__.return_value = cursor
    monkeypatch.setattr(clone_module, "_connect", lambda *_args, **_kwargs: connection)
    monkeypatch.setattr(clone_module, "_guard_clone_connection", lambda *_args, **_kwargs: {})
    tracked: list[str] = []

    with pytest.raises(psycopg.OperationalError):
        clone_module._create_job_database(
            _settings(),
            "advisor_query_ambiguous",
            tracked,
        )

    assert tracked == ["advisor_query_ambiguous"]


def test_successful_evaluation_uses_two_disposable_databases_and_cleans_both(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created: list[str] = []
    cleaned: list[str] = []

    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(clone_module, "_preflight_read_only_query", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(created),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_candidate_index",
        lambda *_args: {
            "indexBuildTimeMs": 12.5,
            "actualIndexSizeBytes": 131_072,
            "tableSizeBytes": 2_097_152,
            "postgresVersion": "18.4",
        },
    )
    monkeypatch.setattr(clone_module, "_benchmark", lambda *_args: _runtime_validation())

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = _evaluate(
        _request(
            normalizedSql="SELECT count(*) FROM orders WHERE status = $1",
            bindValues=["pending"],
        )
    )
    validated = CloneIndexEvaluationResult.model_validate(result)

    assert validated.status == "RUNTIME_VALIDATED"
    assert validated.sourceDdlExecuted is False
    assert validated.cloneDdlExecuted is True
    assert validated.cloneDestroyed is True
    assert len(created) == 2
    assert created == cleaned
    assert created[0].startswith("advisor_base_")
    assert created[1].startswith("advisor_cand_")


def test_failure_after_real_index_still_cleans_every_created_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    cleaned: list[str] = []
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(clone_module, "_preflight_read_only_query", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_candidate_index",
        lambda *_args: {
            "indexBuildTimeMs": 1.0,
            "actualIndexSizeBytes": 1,
            "tableSizeBytes": 1,
            "postgresVersion": "18.4",
        },
    )
    monkeypatch.setattr(
        clone_module,
        "_benchmark",
        lambda *_args: (_ for _ in ()).throw(RuntimeError("plan failed")),
    )

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneIndexEvaluationResult.model_validate(_evaluate(_request()))

    assert result.status == "UNAVAILABLE"
    assert result.reasonCode == "CLONE_EVALUATOR_ERROR"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is True
    assert result.cloneDestroyed is True
    assert len(cleaned) == 2


def test_unsafe_database_preflight_stops_before_candidate_clone_or_index(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created: list[str] = []
    cleaned: list[str] = []
    index_started = False

    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(created),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)

    def reject_preflight(*_args: object) -> None:
        raise CloneEvaluationStop(
            "UNSAFE",
            "READ_ONLY_PLAN_REQUIRED",
            "unsafe plan",
        )

    def create_index(*_args: object) -> dict[str, Any]:
        nonlocal index_started
        index_started = True
        return {}

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_preflight_read_only_query", reject_preflight)
    monkeypatch.setattr(clone_module, "_create_candidate_index", create_index)
    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneIndexEvaluationResult.model_validate(_evaluate(_request()))

    assert result.status == "UNSAFE"
    assert result.reasonCode == "READ_ONLY_PLAN_REQUIRED"
    assert index_started is False
    assert len(created) == 1
    assert cleaned == created


def test_failure_while_granting_runner_tracks_and_drops_the_created_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    cleaned: list[str] = []
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(clone_module, "_preflight_read_only_query", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(),
    )
    monkeypatch.setattr(
        clone_module,
        "_grant_runner_connect",
        lambda *_args: (_ for _ in ()).throw(RuntimeError("grant failed")),
    )

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneIndexEvaluationResult.model_validate(_evaluate(_request()))

    assert result.status == "UNAVAILABLE"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is True
    assert len(cleaned) == 1
    assert cleaned[0].startswith("advisor_base_")


def test_cleanup_failure_overrides_an_otherwise_validated_result(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(clone_module, "_preflight_read_only_query", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_create_candidate_index",
        lambda *_args: {
            "indexBuildTimeMs": 12.5,
            "actualIndexSizeBytes": 131_072,
            "tableSizeBytes": 2_097_152,
            "postgresVersion": "18.4",
        },
    )
    monkeypatch.setattr(clone_module, "_benchmark", lambda *_args: _runtime_validation())
    monkeypatch.setattr(clone_module, "_destroy_job_databases", lambda *_args: False)

    result = CloneIndexEvaluationResult.model_validate(_evaluate(_request()))

    assert result.status == "UNAVAILABLE"
    assert result.reasonCode == "CLONE_CLEANUP_FAILED"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is True
    assert result.cloneDestroyed is False


def test_parameterized_request_never_creates_a_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created = False
    cleanup_names: list[str] | None = None
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)

    def create(*_args: object) -> None:
        nonlocal created
        created = True

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        nonlocal cleanup_names
        cleanup_names = names
        return True

    monkeypatch.setattr(clone_module, "_create_job_database", create)
    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneIndexEvaluationResult.model_validate(
        _evaluate(_request(normalizedSql="SELECT * FROM orders WHERE status = $1"))
    )

    assert result.status == "UNAVAILABLE"
    assert result.reasonCode == "REPLAY_FIXTURE_VALUE_COUNT_MISMATCH"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is True
    assert created is False
    assert cleanup_names == []


def test_direct_query_evaluation_uses_one_clone_without_any_clone_ddl(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created: list[str] = []
    granted: list[str] = []
    cleaned: list[str] = []

    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(created),
    )
    monkeypatch.setattr(
        clone_module,
        "_grant_runner_connect",
        lambda _settings, database_name: granted.append(database_name),
    )
    monkeypatch.setattr(
        clone_module,
        "_create_candidate_index",
        lambda *_args: pytest.fail("direct query path must never create an index"),
    )
    monkeypatch.setattr(
        clone_module,
        "_query_explain_validation",
        lambda *_args: _query_validation(),
    )

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneQueryEvaluationResult.model_validate(
        _evaluate_query(
            _query_request(
                normalizedSql="SELECT * FROM orders WHERE status = $1",
                bindValues=["paid"],
            )
        )
    )

    assert result.status == "RUNTIME_VALIDATED"
    assert result.reasonCode == "READ_ONLY_EXPLAIN_ANALYZE_COMPLETED"
    assert result.queryId == "-42"
    assert result.executionTarget == "DISPOSABLE_CLONE"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is True
    assert result.validation is not None
    assert result.validation.plan["Plan"]["Node Type"] == "Aggregate"
    assert len(created) == 1
    assert created[0].startswith("advisor_query_")
    assert granted == created
    assert cleaned == created


def test_direct_query_rejection_happens_before_a_clone_is_created(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created: list[str] = []
    cleanup_names: list[str] | None = None
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(created),
    )

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        nonlocal cleanup_names
        cleanup_names = names
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneQueryEvaluationResult.model_validate(
        _evaluate_query(_query_request(normalizedSql="SELECT * INTO copied FROM orders"))
    )

    assert result.status == "UNSAFE"
    assert result.reasonCode == "SELECT_ONLY"
    assert result.validation is None
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is True
    assert created == []
    assert cleanup_names == []


def test_direct_query_failure_after_clone_creation_is_cleaned(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    created: list[str] = []
    cleaned: list[str] = []
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(created),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_query_explain_validation",
        lambda *_args: (_ for _ in ()).throw(psycopg.errors.QueryCanceled()),
    )

    def cleanup(_settings: CloneEvaluatorSettings, names: list[str]) -> bool:
        cleaned.extend(names)
        return True

    monkeypatch.setattr(clone_module, "_destroy_job_databases", cleanup)

    result = CloneQueryEvaluationResult.model_validate(
        _evaluate_query(_query_request())
    )

    assert result.status == "UNAVAILABLE"
    assert result.reasonCode == "RUNTIME_QUERY_TIMEOUT"
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is True
    assert len(created) == 1
    assert cleaned == created


def test_direct_query_cleanup_failure_overrides_success(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(
        clone_module,
        "_create_job_database",
        _fake_job_database_creator(),
    )
    monkeypatch.setattr(clone_module, "_grant_runner_connect", lambda *_args: None)
    monkeypatch.setattr(
        clone_module,
        "_query_explain_validation",
        lambda *_args: _query_validation(),
    )
    monkeypatch.setattr(clone_module, "_destroy_job_databases", lambda *_args: False)

    result = CloneQueryEvaluationResult.model_validate(
        _evaluate_query(_query_request())
    )

    assert result.status == "UNAVAILABLE"
    assert result.reasonCode == "CLONE_CLEANUP_FAILED"
    assert result.sourceDdlExecuted is False
    assert result.cloneDdlExecuted is False
    assert result.cloneDestroyed is False


def test_direct_query_internal_endpoint_is_registered() -> None:
    routes = {
        route.path: route
        for route in clone_module.app.routes
        if hasattr(route, "path")
    }
    route = routes["/internal/v1/query-explain-analyze"]
    assert route.methods == {"POST"}
    assert route.response_model is CloneQueryEvaluationResult


def test_cancelled_request_keeps_the_single_evaluator_slot_until_worker_exits() -> None:
    original_slots = clone_module._evaluation_slots
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

    async def scenario() -> None:
        clone_module._evaluation_slots = asyncio.Semaphore(1)
        first = asyncio.create_task(
            clone_module._run_serialized_evaluation(worker, "first")
        )
        assert await asyncio.to_thread(first_started.wait, 1)
        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first

        second = asyncio.create_task(
            clone_module._run_serialized_evaluation(worker, "second")
        )
        await asyncio.sleep(0.05)
        assert not second_started.is_set()

        release_first.set()
        assert await asyncio.wait_for(second, timeout=1) == {"label": "second"}

    try:
        asyncio.run(scenario())
    finally:
        release_first.set()
        clone_module._evaluation_slots = original_slots


def test_internal_token_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        clone_module,
        "get_clone_evaluator_settings",
        lambda: SimpleNamespace(clone_evaluator_token="expected-token"),
    )

    _authorized("expected-token")
    for token in (None, "", "wrong-token"):
        with pytest.raises(HTTPException) as captured:
            _authorized(token)
        assert captured.value.status_code == 401
