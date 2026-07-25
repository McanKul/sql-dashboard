from __future__ import annotations

from types import SimpleNamespace
from typing import Any
from uuid import UUID

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

import app.clone_evaluator as clone_module
from app.clone_evaluator import (
    CloneEvaluationStop,
    CloneEvaluatorSettings,
    CloneIndexEvaluationResult,
    InternalCloneIndexEvaluationRequest,
    ValidatedCloneIndexCandidate,
    _access_method,
    _aggregate_plan_samples,
    _authorized,
    _evaluate,
    _guard_clone_connection,
    _production_index_sql,
    _replay_query,
    _uses_index,
    _validated_request,
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
        ("SELECT '\x00'", "MULTI_STATEMENT_OR_INVALID_SQL"),
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


def test_successful_evaluation_uses_two_disposable_databases_and_cleans_both(
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
        lambda _settings, database_name: created.append(database_name),
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
    monkeypatch.setattr(clone_module, "_create_job_database", lambda *_args: None)
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


def test_failure_while_granting_runner_tracks_and_drops_the_created_database(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = _settings()
    cleaned: list[str] = []
    monkeypatch.setattr(clone_module, "get_clone_evaluator_settings", lambda: settings)
    monkeypatch.setattr(clone_module, "_assert_clone_ready", lambda _settings: {})
    monkeypatch.setattr(clone_module, "_create_job_database", lambda *_args: None)
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
    monkeypatch.setattr(clone_module, "_create_job_database", lambda *_args: None)
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
