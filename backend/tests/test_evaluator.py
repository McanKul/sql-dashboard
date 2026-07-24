from __future__ import annotations

import json
from datetime import datetime, timezone
from types import SimpleNamespace
from typing import Any
from urllib.request import Request

import pytest
from fastapi import HTTPException

import app.api.router as router_module
import app.evaluator as evaluator_module
import app.services.evaluator as evaluator_client_module
from app.evaluator import (
    EvaluationStop,
    _access_method,
    _authorized,
    _plan,
    _proposed_index_sql,
    _replay_sql,
    _uses_hypothetical_index,
)
from app.repositories.powa import repository
from app.schemas import IndexAdvice, IndexEvaluationRequest, InternalIndexEvaluationRequest


def _internal_request(**overrides: object) -> InternalIndexEvaluationRequest:
    values: dict[str, object] = {
        "serverId": 1,
        "serverAlias": "test-source",
        "databaseId": 16384,
        "databaseName": "appdb",
        "queryId": "-42",
        "normalizedSql": "SELECT count(*) FROM orders WHERE status = $1",
        "qualId": "99",
        "relationId": 19877,
        "schemaName": "public",
        "tableName": "orders",
        "columns": ["status"],
        "operatorOids": [98],
        "occurrences": 24,
        "rowsProcessed": 18_000,
        "filterRatio": 0.75,
        "sampleCount": 4,
    }
    values.update(overrides)
    return InternalIndexEvaluationRequest.model_validate(values)


def _validated_advice() -> dict[str, object]:
    return {
        "status": "VALIDATED",
        "reasonCode": "COST_REDUCTION_CONFIRMED",
        "message": "HypoPG sanal indexi planda kullanildi.",
        "candidate": {
            "method": "btree",
            "columns": ["status"],
            "createIndexSql": (
                'CREATE INDEX CONCURRENTLY "idx_advisor_orders_status_deadbeef" '
                'ON "public"."orders" USING btree ("status");'
            ),
            "copyable": True,
        },
        "validation": {
            "mode": "GENERIC_PLAN",
            "hypopgVersion": "1.4.3",
            "baselineTotalCost": 460.26,
            "hypotheticalTotalCost": 110.10,
            "costReductionPercent": 76.08,
            "hypotheticalIndexUsed": True,
            "baselineAccess": "Seq Scan",
            "hypotheticalAccess": "Index Only Scan",
            "estimatedIndexSizeBytes": 131_072,
            "tableSizeBytes": 2_097_152,
            "evaluatedAt": datetime(2026, 7, 24, 14, 0, tzinfo=timezone.utc),
        },
        "confidence": {
            "level": "HIGH",
            "reasons": ["Sanal index PostgreSQL planinda kullanildi."],
        },
        "ddlExecuted": False,
    }


def test_replay_sql_converts_pgss_typed_literals_and_uses_generic_plan() -> None:
    replay, mode = _replay_sql(
        "SELECT * FROM orders "
        "WHERE created_at > now() - interval $1 AND created_at::date = date $2;"
    )

    assert replay == (
        "SELECT * FROM orders "
        "WHERE created_at > now() - $1::interval AND created_at::date = $2::date"
    )
    assert mode == "GENERIC_PLAN"


def test_replay_sql_without_parameters_uses_plain_plan() -> None:
    replay, mode = _replay_sql("  SELECT count(*) FROM orders  ")

    assert replay == "SELECT count(*) FROM orders"
    assert mode == "PLAIN_PLAN"


@pytest.mark.parametrize(
    ("query", "reason_code"),
    [
        ("UPDATE orders SET status = 'paid'", "SELECT_ONLY"),
        ("DELETE FROM orders", "SELECT_ONLY"),
        ("WITH changed AS (DELETE FROM orders RETURNING *) SELECT * FROM changed", "SELECT_ONLY"),
        ("SELECT 1; DROP TABLE orders", "MULTI_STATEMENT_OR_INVALID_SQL"),
        ("SELECT '\x00'", "MULTI_STATEMENT_OR_INVALID_SQL"),
    ],
)
def test_replay_sql_fails_closed_for_writes_and_multiple_statements(
    query: str,
    reason_code: str,
) -> None:
    with pytest.raises(EvaluationStop) as captured:
        _replay_sql(query)

    assert captured.value.reason_code == reason_code
    assert captured.value.result_status == "UNSAFE"


class _PlanCursor:
    def __init__(self, plan: dict[str, Any]):
        self.plan = plan
        self.executed_sql = ""

    def execute(self, statement: Any) -> None:
        self.executed_sql = statement.as_string(None)

    def fetchone(self) -> list[list[dict[str, Any]]]:
        return [[self.plan]]


class _DictPlanCursor(_PlanCursor):
    def fetchone(self) -> dict[str, list[dict[str, Any]]]:
        return {"QUERY PLAN": [self.plan]}


def test_plan_uses_generic_explain_without_executing_analyze() -> None:
    cursor = _PlanCursor({"Plan": {"Node Type": "Seq Scan", "Total Cost": 20.0}})

    result = _plan(cursor, "SELECT * FROM orders WHERE status = $1", "GENERIC_PLAN")

    assert result["Plan"]["Node Type"] == "Seq Scan"
    assert cursor.executed_sql.startswith("EXPLAIN (FORMAT JSON, GENERIC_PLAN TRUE) SELECT")
    assert "ANALYZE" not in cursor.executed_sql.upper()


def test_plan_accepts_the_evaluator_connection_dict_row_shape() -> None:
    cursor = _DictPlanCursor({"Plan": {"Node Type": "Seq Scan", "Total Cost": 20.0}})

    result = _plan(cursor, "SELECT * FROM orders", "PLAIN_PLAN")

    assert result["Plan"]["Total Cost"] == 20.0


def test_nested_plan_helpers_find_access_and_only_the_expected_hypothetical_index() -> None:
    plan = {
        "Plan": {
            "Node Type": "Aggregate",
            "Plans": [
                {
                    "Node Type": "Nested Loop",
                    "Plans": [
                        {"Node Type": "Seq Scan", "Relation Name": "customers"},
                        {
                            "Node Type": "Index Scan",
                            "Relation Name": "orders",
                            "Index Name": "<42000>btree_hypo_orders_status",
                        },
                    ],
                }
            ],
        }
    }

    assert _access_method(plan, "orders") == "Index Scan"
    assert _uses_hypothetical_index(plan, 42000, "ignored-name") is True
    assert _uses_hypothetical_index(plan, 42001, "another-index") is False


def test_copyable_index_sql_quotes_every_identifier() -> None:
    ddl = _proposed_index_sql(
        None,  # psycopg composables can render identifiers without a live connection.
        'pub"lic',
        'orders"; DROP TABLE secrets; --',
        'sta"tus',
    )

    assert ddl.startswith('CREATE INDEX CONCURRENTLY "idx_advisor_')
    assert 'ON "pub""lic"."orders""; DROP TABLE secrets; --"' in ddl
    assert 'USING btree ("sta""tus");' in ddl


def test_internal_evaluator_token_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        evaluator_module,
        "get_evaluator_settings",
        lambda: SimpleNamespace(evaluator_token="expected-token"),
    )

    _authorized("expected-token")
    for token in (None, "", "wrong-token"):
        with pytest.raises(HTTPException) as captured:
            _authorized(token)
        assert captured.value.status_code == 401


@pytest.mark.asyncio
async def test_public_api_builds_internal_request_from_repository_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, InternalIndexEvaluationRequest] = {}

    async def predicate_evidence(**kwargs: object) -> tuple[list[dict[str, object]], dict[str, object]]:
        assert kwargs == {
            "window": "24h",
            "server_id": 1,
            "database_id": 16384,
            "query_id": -42,
        }
        return [
            {
                "server_id": 1,
                "server_alias": "test-source",
                "database_id": 16384,
                "database_name": "appdb",
                "query_id": -42,
                "qual_id": 99,
                "relation_id": 19877,
                "schema_name": "public",
                "table_name": "orders",
                "column_names": ["status"],
                "operator_oids": [98],
                "eval_type": "FILTER",
                "occurrences": 24,
                "rows_processed": 18_000,
                "filter_ratio": 0.75,
                "sample_count": 4,
                "signal": "INDEX_CANDIDATE",
            }
        ], {"available": True, "version": "2.1.4"}

    async def query_by_id(**kwargs: object) -> dict[str, object]:
        assert kwargs == {
            "query_id": -42,
            "window": "24h",
            "server_id": 1,
            "database_id": 16384,
        }
        return {"sql_text": "SELECT count(*) FROM orders WHERE status = $1"}

    async def evaluate_index_candidate(
        request: InternalIndexEvaluationRequest,
    ) -> dict[str, object]:
        captured["request"] = request
        return _validated_advice()

    monkeypatch.setattr(repository, "predicate_evidence", predicate_evidence)
    monkeypatch.setattr(repository, "query_by_id", query_by_id)
    monkeypatch.setattr(router_module, "evaluate_index_candidate", evaluate_index_candidate)

    result = await router_module.evaluate_query_index(
        query_id=-42,
        payload=IndexEvaluationRequest(
            serverId=1,
            databaseId=16384,
            qualId="99",
            relationId=19877,
        ),
        role="analyst",
        window="24h",
    )

    request = captured["request"]
    assert request.normalizedSql == "SELECT count(*) FROM orders WHERE status = $1"
    assert request.serverAlias == "test-source"
    assert request.databaseName == "appdb"
    assert request.columns == ["status"]
    assert request.operatorOids == [98]
    assert request.occurrences == 24
    assert request.rowsProcessed == 18_000

    response = IndexAdvice.model_validate(result)
    assert response.status == "VALIDATED"
    assert response.candidate is not None
    assert response.candidate.copyable is True
    assert response.validation is not None
    assert response.validation.hypotheticalIndexUsed is True
    assert response.ddlExecuted is False


@pytest.mark.asyncio
async def test_public_api_rejects_viewer_before_repository_or_evaluator_access(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def must_not_run(**_: object) -> Any:
        pytest.fail("viewer istegi repository veya evaluator'a ulasmamali")

    monkeypatch.setattr(repository, "predicate_evidence", must_not_run)
    monkeypatch.setattr(router_module, "evaluate_index_candidate", must_not_run)

    with pytest.raises(HTTPException) as captured:
        await router_module.evaluate_query_index(
            query_id=-42,
            payload=IndexEvaluationRequest(
                serverId=1,
                databaseId=16384,
                qualId="99",
                relationId=19877,
            ),
            role="viewer",
            window="24h",
        )

    assert captured.value.status_code == 403


class _HttpResponse:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self) -> _HttpResponse:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


def test_api_evaluator_client_sends_token_and_validates_response_contract(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, object] = {}
    response_body = json.dumps(
        IndexAdvice.model_validate(_validated_advice()).model_dump(mode="json")
    ).encode("utf-8")

    monkeypatch.setattr(
        evaluator_client_module,
        "get_settings",
        lambda: SimpleNamespace(
            evaluator_url="http://evaluator:8010/",
            evaluator_token="internal-token",
            evaluator_timeout_seconds=4.0,
        ),
    )

    def fake_urlopen(request: Request, timeout: float) -> _HttpResponse:
        captured["url"] = request.full_url
        captured["method"] = request.method
        captured["token"] = request.get_header("X-evaluator-token")
        captured["body"] = json.loads((request.data or b"").decode("utf-8"))
        captured["timeout"] = timeout
        return _HttpResponse(response_body)

    monkeypatch.setattr(evaluator_client_module, "urlopen", fake_urlopen)

    result = evaluator_client_module._post_evaluation(_internal_request())

    assert captured == {
        "url": "http://evaluator:8010/internal/v1/index-evaluations",
        "method": "POST",
        "token": "internal-token",
        "body": _internal_request().model_dump(mode="json"),
        "timeout": 4.0,
    }
    assert result["status"] == "VALIDATED"
    assert result["ddlExecuted"] is False


def test_api_evaluator_client_rejects_response_claiming_ddl_execution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    unsafe_response = {**_validated_advice(), "ddlExecuted": True}
    monkeypatch.setattr(
        evaluator_client_module,
        "get_settings",
        lambda: SimpleNamespace(
            evaluator_url="http://evaluator:8010",
            evaluator_token="internal-token",
            evaluator_timeout_seconds=4.0,
        ),
    )
    monkeypatch.setattr(
        evaluator_client_module,
        "urlopen",
        lambda *_args, **_kwargs: _HttpResponse(json.dumps(unsafe_response, default=str).encode()),
    )

    result = evaluator_client_module._post_evaluation(_internal_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "EVALUATOR_UNREACHABLE"
    assert result["candidate"] is None
    assert result["ddlExecuted"] is False
