from __future__ import annotations

import json
from http.client import IncompleteRead
from types import SimpleNamespace
from typing import Any
from urllib.error import URLError
from urllib.request import Request

from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError
import pytest

import app.api.router as router_module
from app.api.router import router
from app.clone_evaluator import (
    CloneQueryEvaluationResult,
    InternalCloneQueryEvaluationRequest,
)
from app.repositories.powa import repository
from app.schemas import QueryExplainAnalyzeRequest
import app.services.clone_evaluator as clone_client
import app.services.evaluator as evaluator_client
from app.schemas import InternalQueryExplainAnalyzeRequest


def _clone_runtime_result(query_id: str = "-42") -> dict[str, Any]:
    return {
        "status": "RUNTIME_VALIDATED",
        "reasonCode": "READ_ONLY_EXPLAIN_ANALYZE_COMPLETED",
        "message": "Disposable clone uzerinde tamamlandi.",
        "queryId": query_id,
        "validation": {
            "mode": "EXPLAIN_ANALYZE",
            "statementClass": "READ_ONLY_SELECT",
            "planPreflight": "READ_ONLY",
            "transactionReadOnly": True,
            "runnerPolicyRevision": 1,
            "postgresVersion": "18.4",
            "executionTimeMs": 2.5,
            "planningTimeMs": 0.4,
            "sharedHitBlocks": 12,
            "sharedReadBlocks": 1,
            "tempReadBlocks": 0,
            "tempWrittenBlocks": 0,
            "walRecords": 0,
            "walBytes": 0,
            "plan": {"Plan": {"Node Type": "Aggregate"}},
            "evaluatedAt": "2026-07-26T12:00:00Z",
        },
        "executionTarget": "DISPOSABLE_CLONE",
        "sourceDdlExecuted": False,
        "cloneDdlExecuted": False,
        "cloneDestroyed": True,
    }


def _source_runtime_result(query_id: str = "-42") -> dict[str, Any]:
    clone = _clone_runtime_result(query_id)
    raw_validation = dict(clone["validation"])
    policy_revision = raw_validation.pop("runnerPolicyRevision")
    validation = {
        **raw_validation,
        "safetyPolicyRevision": policy_revision,
        "executionRole": "advisor_evaluator",
        "databaseId": 16_384,
    }
    return {
        "status": "RUNTIME_VALIDATED",
        "reasonCode": "SOURCE_READ_ONLY_EXPLAIN_ANALYZE_COMPLETED",
        "message": "Ana veritabaninda tamamlandi.",
        "queryId": query_id,
        "validation": validation,
        "executionTarget": "SOURCE_DATABASE",
        "sourceExecuted": True,
        "sourceDdlExecuted": False,
        "transactionRolledBack": True,
    }


@pytest.fixture
def client() -> TestClient:
    application = FastAPI()
    application.include_router(router)
    return TestClient(application)


def test_query_explain_route_needs_no_admin_and_uses_only_persisted_sql(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    persisted_sql = "SELECT count(*) FROM public.orders WHERE status = $1"

    async def query_by_id(**kwargs: Any) -> dict[str, Any]:
        captured["repository"] = kwargs
        return {
            "server_alias": "erp-primary",
            "database_name": "erp",
            "sql_text": persisted_sql,
        }

    async def explain(payload: InternalQueryExplainAnalyzeRequest) -> dict[str, Any]:
        captured["source_request"] = payload
        return _source_runtime_result(payload.queryId)

    monkeypatch.setattr(repository, "query_by_id", query_by_id)
    monkeypatch.setattr(router_module, "explain_query_on_source", explain)

    # No bearer/admin header: this route is intentionally available on the
    # single-user loopback dashboard deployment.
    response = client.post(
        "/api/v1/queries/-42/explain-analyze?window=7d",
        json={"serverId": 7, "databaseId": 16_384, "bindValues": ["paid"]},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "RUNTIME_VALIDATED"
    assert captured["repository"] == {
        "query_id": -42,
        "window": "7d",
        "server_id": 7,
        "database_id": 16_384,
    }
    internal = captured["source_request"]
    assert internal.normalizedSql == persisted_sql
    assert internal.serverId == 7
    assert internal.serverAlias == "erp-primary"
    assert internal.databaseId == 16_384
    assert internal.databaseName == "erp"
    assert internal.queryId == "-42"
    assert internal.bindValues == ["paid"]


def test_query_explain_route_rejects_caller_supplied_sql_before_repository_access(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def forbidden(**_: Any) -> None:
        raise AssertionError("invalid body must not reach repository")

    monkeypatch.setattr(repository, "query_by_id", forbidden)

    response = client.post(
        "/api/v1/queries/42/explain-analyze?window=24h",
        json={
            "serverId": 1,
            "databaseId": 16_384,
            "bindValues": [],
            "sql": "DELETE FROM public.orders",
            "normalizedSql": "SELECT pg_sleep(60)",
        },
    )

    assert response.status_code == 422
    rejected_fields = {tuple(error["loc"]) for error in response.json()["detail"]}
    assert ("body", "sql") in rejected_fields
    assert ("body", "normalizedSql") in rejected_fields


def test_query_explain_route_returns_404_for_missing_persisted_query(
    client: TestClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def missing(**_: Any) -> None:
        return None

    async def forbidden(*_: Any, **__: Any) -> None:
        raise AssertionError("missing query must not reach clone evaluator")

    monkeypatch.setattr(repository, "query_by_id", missing)
    monkeypatch.setattr(router_module, "explain_query_on_source", forbidden)

    response = client.post(
        "/api/v1/queries/42/explain-analyze?window=24h",
        json={"serverId": 1, "databaseId": 16_384, "bindValues": []},
    )

    assert response.status_code == 404


@pytest.mark.parametrize(
    "bind_values",
    [
        [0] * 129,
        ["x" * 2_049],
        [{"nested": "value"}],
        ["x" * 2_048] * 33,
        [float("nan")],
        [float("inf")],
    ],
)
def test_query_explain_bind_values_are_strictly_bounded(bind_values: list[Any]) -> None:
    with pytest.raises(ValidationError):
        QueryExplainAnalyzeRequest(
            serverId=1,
            databaseId=16_384,
            bindValues=bind_values,
        )


class _HttpResponse:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self) -> _HttpResponse:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


class _IncompleteHttpResponse(_HttpResponse):
    def read(self) -> bytes:
        raise IncompleteRead(self.body, len(self.body) + 1)


def _internal_source_request() -> InternalQueryExplainAnalyzeRequest:
    return InternalQueryExplainAnalyzeRequest(
        serverId=1,
        serverAlias="erp-primary",
        databaseId=16_384,
        databaseName="erp",
        queryId="-42",
        normalizedSql="SELECT count(*) FROM public.orders WHERE status = $1",
        bindValues=["paid"],
    )


def test_source_query_explain_client_sends_token_and_validates_contract(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    monkeypatch.setattr(
        evaluator_client,
        "get_settings",
        lambda: SimpleNamespace(
            evaluator_url="http://evaluator:8010/",
            evaluator_token="internal-secret",
            source_explain_timeout_seconds=130.0,
        ),
    )

    def fake_urlopen(request: Request, timeout: float) -> _HttpResponse:
        captured["url"] = request.full_url
        captured["method"] = request.method
        captured["token"] = request.get_header("X-evaluator-token")
        captured["body"] = json.loads((request.data or b"").decode("utf-8"))
        captured["timeout"] = timeout
        return _HttpResponse(json.dumps(_source_runtime_result()).encode("utf-8"))

    monkeypatch.setattr(evaluator_client, "urlopen", fake_urlopen)

    result = evaluator_client._post_source_query_explain(_internal_source_request())

    assert captured == {
        "url": "http://evaluator:8010/internal/v1/query-explain-analyze",
        "method": "POST",
        "token": "internal-secret",
        "body": _internal_source_request().model_dump(mode="json"),
        "timeout": 130.0,
    }
    assert result["status"] == "RUNTIME_VALIDATED"
    assert result["executionTarget"] == "SOURCE_DATABASE"
    assert result["sourceExecuted"] is True
    assert result["transactionRolledBack"] is True


@pytest.mark.parametrize(
    "failure",
    [
        "unreachable",
        "query-mismatch",
        "database-mismatch",
        "missing-validation",
        "malformed-plan",
    ],
)
def test_source_query_explain_client_fails_closed_with_unknown_execution_state(
    failure: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        evaluator_client,
        "get_settings",
        lambda: SimpleNamespace(
            evaluator_url="http://evaluator:8010",
            evaluator_token="internal-secret",
            source_explain_timeout_seconds=130.0,
        ),
    )

    if failure == "unreachable":
        monkeypatch.setattr(
            evaluator_client,
            "urlopen",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(URLError("offline")),
        )
    elif failure == "query-mismatch":
        monkeypatch.setattr(
            evaluator_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(
                json.dumps(_source_runtime_result("999")).encode("utf-8")
            ),
        )
    elif failure == "database-mismatch":
        invalid = _source_runtime_result()
        invalid["validation"] = {
            **invalid["validation"],
            "databaseId": 99_999,
        }
        monkeypatch.setattr(
            evaluator_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(json.dumps(invalid).encode("utf-8")),
        )
    elif failure == "malformed-plan":
        invalid = _source_runtime_result()
        invalid["validation"] = {
            **invalid["validation"],
            "plan": {"Plan": "not-a-node-tree"},
        }
        monkeypatch.setattr(
            evaluator_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(json.dumps(invalid).encode("utf-8")),
        )
    else:
        invalid = {**_source_runtime_result(), "validation": None}
        monkeypatch.setattr(
            evaluator_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(json.dumps(invalid).encode("utf-8")),
        )

    result = evaluator_client._post_source_query_explain(_internal_source_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "SOURCE_EVALUATOR_UNREACHABLE"
    assert result["sourceExecuted"] is None
    assert result["transactionRolledBack"] is None


def _internal_request() -> InternalCloneQueryEvaluationRequest:
    return InternalCloneQueryEvaluationRequest(
        serverAlias="erp-primary",
        databaseName="erp",
        queryId="-42",
        normalizedSql="SELECT count(*) FROM public.orders WHERE status = $1",
        bindValues=["paid"],
    )


def test_query_explain_client_sends_internal_token_and_validates_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}
    monkeypatch.setattr(
        clone_client,
        "get_settings",
        lambda: SimpleNamespace(
            clone_evaluator_url="http://clone-evaluator:8020/",
            clone_evaluator_token="internal-secret",
            clone_evaluator_timeout_seconds=90.0,
        ),
    )

    def fake_urlopen(request: Request, timeout: float) -> _HttpResponse:
        captured["url"] = request.full_url
        captured["method"] = request.method
        captured["token"] = request.get_header("X-clone-evaluator-token")
        captured["body"] = json.loads((request.data or b"").decode("utf-8"))
        captured["timeout"] = timeout
        return _HttpResponse(json.dumps(_clone_runtime_result()).encode("utf-8"))

    monkeypatch.setattr(clone_client, "urlopen", fake_urlopen)

    result = clone_client._post_query_explain(_internal_request())

    assert captured == {
        "url": "http://clone-evaluator:8020/internal/v1/query-explain-analyze",
        "method": "POST",
        "token": "internal-secret",
        "body": _internal_request().model_dump(mode="json"),
        "timeout": 90.0,
    }
    assert result["status"] == "RUNTIME_VALIDATED"
    assert result["sourceDdlExecuted"] is False
    assert result["cloneDdlExecuted"] is False


@pytest.mark.parametrize(
    "failure",
    [
        "unreachable",
        "unsafe-response",
        "query-mismatch",
        "missing-validation",
        "cleanup-incomplete",
        "incomplete-http-response",
    ],
)
def test_query_explain_client_fails_closed(
    failure: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        clone_client,
        "get_settings",
        lambda: SimpleNamespace(
            clone_evaluator_url="http://clone-evaluator:8020",
            clone_evaluator_token="internal-secret",
            clone_evaluator_timeout_seconds=3.0,
        ),
    )
    if failure == "unreachable":
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(URLError("offline")),
        )
    elif failure == "unsafe-response":
        unsafe = {**_clone_runtime_result(), "sourceDdlExecuted": True}
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(json.dumps(unsafe).encode("utf-8")),
        )
    elif failure == "query-mismatch":
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(
                json.dumps(_clone_runtime_result("999")).encode("utf-8")
            ),
        )
    elif failure == "missing-validation":
        incomplete = {**_clone_runtime_result(), "validation": None}
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(
                json.dumps(incomplete).encode("utf-8")
            ),
        )
    elif failure == "cleanup-incomplete":
        incomplete = {**_clone_runtime_result(), "cloneDestroyed": False}
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: _HttpResponse(
                json.dumps(incomplete).encode("utf-8")
            ),
        )
    else:
        monkeypatch.setattr(
            clone_client,
            "urlopen",
            lambda *_args, **_kwargs: _IncompleteHttpResponse(b"{"),
        )

    result = clone_client._post_query_explain(_internal_request())

    assert result == {
        "status": "UNAVAILABLE",
        "reasonCode": "CLONE_EVALUATOR_UNREACHABLE",
        "message": "Disposable clone evaluator yanit vermedi; kaynak sorgu calistirilmadi.",
        "queryId": "-42",
        "validation": None,
        "executionTarget": "DISPOSABLE_CLONE",
        "sourceDdlExecuted": False,
        "cloneDdlExecuted": False,
        "cloneDestroyed": False,
    }


@pytest.mark.parametrize(
    "invalid_result",
    [
        {**_clone_runtime_result(), "validation": None},
        {**_clone_runtime_result(), "cloneDestroyed": False},
    ],
)
def test_runtime_validated_response_requires_evidence_and_cleanup(
    invalid_result: dict[str, Any],
) -> None:
    with pytest.raises(ValidationError):
        CloneQueryEvaluationResult.model_validate(invalid_result)


def test_query_explain_client_handles_malformed_configured_url_as_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        clone_client,
        "get_settings",
        lambda: SimpleNamespace(
            clone_evaluator_url="://invalid",
            clone_evaluator_token="internal-secret",
            clone_evaluator_timeout_seconds=3.0,
        ),
    )

    result = clone_client._post_query_explain(_internal_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "CLONE_EVALUATOR_UNREACHABLE"
    assert result["queryId"] == "-42"
    assert result["cloneDestroyed"] is False


def test_query_explain_client_returns_unavailable_when_not_configured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        clone_client,
        "get_settings",
        lambda: SimpleNamespace(clone_evaluator_url=None),
    )

    result = clone_client._post_query_explain(_internal_request())

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "CLONE_EVALUATOR_NOT_CONFIGURED"
    assert result["sourceDdlExecuted"] is False
    assert result["cloneDdlExecuted"] is False
    assert result["cloneDestroyed"] is True
