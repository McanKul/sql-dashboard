from __future__ import annotations

import uuid
from typing import Any

import pytest

import app.api.router as router_module
from app.api.router import validate_query_index_runtime
from app.repositories.powa import repository
from app.schemas import RuntimeIndexValidationRequest
from app.security import RequestPrincipal


CANDIDATE_ID = "d3cc4474-0303-4a6f-b26f-82ad6d4e58a7"
ADMIN_PRINCIPAL = RequestPrincipal(
    credential_id="runtime-test",
    subject="user:runtime-test",
    roles=frozenset({"admin"}),
)


def _candidate() -> dict[str, Any]:
    return {
        "candidate_id": CANDIDATE_ID,
        "relation_id": 16_401,
        "schema_name": "public",
        "table_name": "orders",
        "key_column_names": ["status", "customer_id"],
        "operator_oids": [98, 96],
        "join_occurrences": 40,
        "filter_occurrences": 40,
        "rows_processed": 2_000,
        "filter_ratio": 0.75,
        "sample_count": 4,
    }


def _query() -> dict[str, Any]:
    return {
        "server_alias": "test-source",
        "database_name": "appdb",
        "sql_text": (
            "SELECT count(*) FROM public.customers AS c "
            "JOIN public.orders AS o ON o.customer_id = c.id "
            "WHERE o.status = $1"
        ),
    }


def _payload() -> RuntimeIndexValidationRequest:
    return RuntimeIndexValidationRequest(
        serverId=1,
        databaseId=16_384,
        candidateId=CANDIDATE_ID,
    )


@pytest.mark.asyncio
async def test_runtime_route_never_starts_planner_or_clone_without_fixture(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def candidate(**_: object) -> dict[str, Any]:
        return _candidate()

    async def query(**_: object) -> dict[str, Any]:
        return _query()

    async def fixture(**_: object) -> None:
        return None

    async def forbidden(*_: object, **__: object) -> dict[str, Any]:
        raise AssertionError("fixture yokken evaluator cagrilmamali")

    monkeypatch.setattr(repository, "composite_candidate", candidate)
    monkeypatch.setattr(repository, "query_by_id", query)
    monkeypatch.setattr(repository, "runtime_replay_fixture", fixture)
    monkeypatch.setattr(router_module, "evaluate_index_candidate", forbidden)
    monkeypatch.setattr(router_module, "validate_index_on_clone", forbidden)

    result = await validate_query_index_runtime(
        query_id=-42,
        payload=_payload(),
        principal=ADMIN_PRINCIPAL,
        window="24h",
    )

    assert result["status"] == "UNAVAILABLE"
    assert result["reasonCode"] == "REPLAY_FIXTURE_REQUIRED"
    assert result["sourceDdlExecuted"] is False
    assert result["cloneDdlExecuted"] is False
    assert result["cloneDestroyed"] is True


@pytest.mark.asyncio
async def test_runtime_route_forwards_private_fixture_only_to_internal_clone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, Any] = {}

    async def candidate(**_: object) -> dict[str, Any]:
        return _candidate()

    async def query(**_: object) -> dict[str, Any]:
        return _query()

    async def fixture(**_: object) -> dict[str, Any]:
        return {
            "bind_values": ["paid"],
            "value_class": "SYNTHETIC",
            "approved_by": "acceptance-operator",
            "approval_ticket": "ACCEPT-27",
        }

    async def planner(payload: object) -> dict[str, Any]:
        captured["planner"] = payload
        return {"status": "VALIDATED", "message": "planner accepted"}

    async def clone(payload: object) -> dict[str, Any]:
        captured["clone"] = payload
        return {
            "status": "RUNTIME_VALIDATED",
            "reasonCode": "RUNTIME_INDEX_USED",
            "message": "clone accepted",
            "candidateId": uuid.UUID(CANDIDATE_ID),
            "validation": None,
            "ddlTarget": "DISPOSABLE_CLONE",
            "sourceDdlExecuted": False,
            "cloneDdlExecuted": True,
            "cloneDestroyed": True,
        }

    monkeypatch.setattr(repository, "composite_candidate", candidate)
    monkeypatch.setattr(repository, "query_by_id", query)
    monkeypatch.setattr(repository, "runtime_replay_fixture", fixture)
    monkeypatch.setattr(router_module, "evaluate_index_candidate", planner)
    monkeypatch.setattr(router_module, "validate_index_on_clone", clone)

    result = await validate_query_index_runtime(
        query_id=-42,
        payload=_payload(),
        principal=ADMIN_PRINCIPAL,
        window="24h",
    )

    internal_request = captured["clone"]
    assert internal_request.bindValues == ["paid"]
    assert internal_request.normalizedSql == _query()["sql_text"]
    assert internal_request.candidate.columns == ["status", "customer_id"]
    assert result["status"] == "RUNTIME_VALIDATED"
    assert "paid" not in str(result)
    assert result["sourceDdlExecuted"] is False
    assert result["cloneDestroyed"] is True
