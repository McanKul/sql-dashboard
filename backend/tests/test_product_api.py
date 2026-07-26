from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

import pytest
from fastapi import HTTPException

import app.api.router as router_module
import app.repositories.powa as powa_module
from app.api.router import (
    _release_payload,
    _scope_payload,
    capabilities,
    database_optimize,
    export_queries,
    indexes,
    io_telemetry,
    queries,
)
from app.repositories.powa import PowaRepository
from app.main import app as api_app
from app.evaluator import app as evaluator_app
from app.clone_evaluator import app as clone_app
from app.security import RequestPrincipal


ADMIN_PRINCIPAL = RequestPrincipal(
    credential_id="product-test",
    subject="test:product",
    roles=frozenset({"admin"}),
)


@pytest.mark.asyncio
async def test_scope_requires_server_for_database() -> None:
    with pytest.raises(HTTPException) as captured:
        await _scope_payload(window="24h", server_id=None, database_id=16_384)
    assert captured.value.status_code == 422


@pytest.mark.asyncio
async def test_scope_validates_exact_server_database_pair(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def resolve_scope(**kwargs: object) -> dict[str, object] | None:
        assert kwargs == {"server_id": 7, "database_id": 19}
        return {
            "server_id": 7,
            "server_alias": "erp-prod",
            "database_id": 19,
            "database_name": "erp",
        }

    monkeypatch.setattr(router_module.repository, "resolve_scope", resolve_scope)
    scope = await _scope_payload(window="7d", server_id=7, database_id=19)
    assert scope == {
        "serverId": 7,
        "serverAlias": "erp-prod",
        "databaseId": 19,
        "databaseName": "erp",
        "window": "7d",
    }


async def _invoke_optional_scope_endpoint(
    endpoint: str,
    *,
    server_id: int | None,
    database_id: int | None,
) -> object:
    if endpoint == "queries":
        return await queries(
            role="analyst",
            window="24h",
            page=1,
            page_size=50,
            search=None,
            priority=None,
            server_id=server_id,
            database_id=database_id,
            min_calls=0,
            min_duration_ms=0,
            sort_by="impact",
        )
    if endpoint == "indexes":
        return await indexes(
            window="24h", server_id=server_id, database_id=database_id
        )
    if endpoint == "io":
        return await io_telemetry(
            window="24h", server_id=server_id, database_id=database_id
        )
    if endpoint == "csv":
        return await export_queries(
            principal=ADMIN_PRINCIPAL,
            window="24h",
            search=None,
            priority=None,
            server_id=server_id,
            database_id=database_id,
            min_calls=0,
            min_duration_ms=0,
            sort_by="impact",
        )
    raise AssertionError(f"unknown endpoint: {endpoint}")


@pytest.mark.asyncio
@pytest.mark.parametrize("endpoint", ("queries", "indexes", "io", "csv"))
async def test_optional_scope_endpoints_require_server_for_database(
    endpoint: str,
) -> None:
    with pytest.raises(HTTPException) as captured:
        await _invoke_optional_scope_endpoint(
            endpoint, server_id=None, database_id=19
        )
    assert captured.value.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("endpoint", ("queries", "indexes", "io", "csv"))
async def test_optional_scope_endpoints_reject_unknown_exact_pair(
    endpoint: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def missing_scope(**kwargs: object) -> None:
        assert kwargs == {"server_id": 7, "database_id": 19}
        return None

    monkeypatch.setattr(router_module.repository, "resolve_scope", missing_scope)
    with pytest.raises(HTTPException) as captured:
        await _invoke_optional_scope_endpoint(
            endpoint, server_id=7, database_id=19
        )
    assert captured.value.status_code == 404


def _capability_row() -> dict[str, object]:
    return {
        "server_id": 7,
        "server_alias": "erp-prod",
        "database_id": 19,
        "database_name": "erp",
        "collector_status": "HEALTHY",
        "historical_data_available": True,
        "kcache_configured": True,
        "kcache_version": "2.3.2",
        "cpu_data_available": False,
        "wait_configured": True,
        "wait_version": "1.1",
        "wait_data_available": True,
        "predicate_configured": True,
        "predicate_version": "2.1.4",
        "predicate_data_available": True,
        "join_configured": False,
        "join_data_available": False,
        "join_status": "UNAVAILABLE",
        "join_reason": "not configured",
    }


@pytest.mark.asyncio
async def test_capability_matrix_matches_exact_evaluator_target_and_keeps_no_data(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def rows(**_: object) -> list[dict[str, object]]:
        return [_capability_row()]

    async def health() -> dict[str, dict[str, object]]:
        return {
            "evaluator": {
                "status": "healthy",
                "databaseName": "erp",
                "hypopg_version": "1.4.3",
            },
            "clone": {
                "status": "healthy",
                "sourceAlias": "erp-prod",
                "sourceDatabaseName": "erp",
            },
        }

    monkeypatch.setattr(router_module.repository, "capability_rows", rows)
    monkeypatch.setattr(router_module, "evaluator_health", health)
    monkeypatch.setattr(router_module.settings, "evaluator_url", "http://evaluator")
    monkeypatch.setattr(router_module.settings, "evaluator_allowed_server_alias", "erp-prod")
    monkeypatch.setattr(router_module.settings, "evaluator_allowed_database", "erp")
    monkeypatch.setattr(router_module.settings, "clone_evaluator_url", "http://clone")

    result = await capabilities(window="24h", server_id=None, database_id=None)
    matrix = {item["key"]: item for item in result["items"][0]["capabilities"]}
    assert matrix["hypopg"]["status"] == "AVAILABLE"
    assert matrix["sourceExplain"]["status"] == "AVAILABLE"
    assert matrix["cloneValidation"]["status"] == "AVAILABLE"
    assert matrix["cpuMetrics"]["status"] == "WAITING_FOR_DATA"
    assert matrix["cpuMetrics"]["configured"] is True
    assert matrix["cpuMetrics"]["dataAvailable"] is False
    assert len(matrix) == 8


@pytest.mark.asyncio
async def test_capability_matrix_marks_matching_unreachable_evaluator(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def rows(**_: object) -> list[dict[str, object]]:
        row = _capability_row()
        row.update(server_alias="test-source", database_name="appdb")
        return [row]

    async def health() -> dict[str, None]:
        return {"evaluator": None, "clone": None}

    monkeypatch.setattr(router_module.repository, "capability_rows", rows)
    monkeypatch.setattr(router_module, "evaluator_health", health)
    monkeypatch.setattr(router_module.settings, "evaluator_url", "http://evaluator")
    monkeypatch.setattr(router_module.settings, "evaluator_allowed_server_alias", "test-source")
    monkeypatch.setattr(router_module.settings, "evaluator_allowed_database", "appdb")

    result = await capabilities(window="24h", server_id=None, database_id=None)
    matrix = {item["key"]: item for item in result["items"][0]["capabilities"]}
    assert matrix["hypopg"]["status"] == "UNREACHABLE"
    assert matrix["sourceExplain"]["available"] is False


class _Cursor:
    def __init__(self, pool: _Pool) -> None:
        self.pool = pool

    async def __aenter__(self) -> _Cursor:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    async def execute(self, query: str, params: object) -> None:
        self.pool.executions.append((query, params))

    async def fetchall(self) -> list[dict[str, Any]]:
        return self.pool.batches.pop(0)


class _Connection:
    def __init__(self, pool: _Pool) -> None:
        self.pool = pool

    async def __aenter__(self) -> _Connection:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    def cursor(self) -> _Cursor:
        return _Cursor(self.pool)


class _Pool:
    def __init__(self, batches: list[list[dict[str, Any]]]) -> None:
        self.batches = batches
        self.executions: list[tuple[str, object]] = []

    def connection(self) -> _Connection:
        return _Connection(self)


@pytest.mark.asyncio
async def test_capability_rows_materialize_predicate_and_join_evidence_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_pool = _Pool(
        [[
            {
                "server_id": 7,
                "database_id": 19,
                "historical_data_available": True,
                "cpu_data_available": True,
                "wait_data_available": True,
                "predicate_data_available": True,
                "join_data_available": True,
            },
            {
                "server_id": 7,
                "database_id": 20,
                # Historical statements alone are not wait evidence.
                "historical_data_available": True,
                "cpu_data_available": False,
                "wait_data_available": False,
                "predicate_data_available": False,
                "join_data_available": False,
            },
        ]]
    )
    monkeypatch.setattr(powa_module, "pool", fake_pool)
    scoped_repository = PowaRepository()

    async def metrics_snapshot(_: str) -> list[dict[str, object]]:
        raise AssertionError("capability discovery loaded the full metrics snapshot")

    monkeypatch.setattr(
        scoped_repository, "_query_metrics_snapshot", metrics_snapshot
    )
    rows = await scoped_repository.capability_rows(
        window="24h", server_id=7, database_id=None
    )

    query, params = fake_pool.executions[0]
    compact_query = " ".join(query.split())
    assert "advisor.query_metrics(" not in compact_query
    assert "telemetry_data AS MATERIALIZED" in compact_query
    assert "kcache_data AS MATERIALIZED" in compact_query
    assert "wait_data AS MATERIALIZED" in compact_query
    assert "statement.last_present_ts >= requested.observed_until - requested.metric_window" in compact_query
    assert 'EXISTS ( SELECT 1 FROM "PoWA".powa_snapshot_metas AS snapshot' in compact_query
    assert 'JOIN "PoWA".powa_snapshot_metas AS snapshot' not in compact_query
    assert "history.coalesce_range && tstzrange(" in compact_query
    assert "candidate_query_ids" not in compact_query
    assert "[1:8]" not in compact_query
    assert "WHERE requested.database_id IS NOT NULL AND ( EXISTS" in compact_query
    assert query.count('"PoWA".powa_kcache_metrics') == 4
    assert query.count('"PoWA".powa_wait_sampling_history') == 4
    assert "COALESCE(wait_metric.data_available, false) AS wait_data_available" in compact_query
    assert query.count("advisor.predicate_metrics(") == 1
    assert query.count("advisor.join_predicate_metrics(") == 1
    assert "predicate_data AS MATERIALIZED" in compact_query
    assert "join_data AS MATERIALIZED" in compact_query
    assert "EXISTS ( SELECT 1 FROM advisor.predicate_metrics" not in compact_query
    assert "join_data.database_id = database.oid" in compact_query
    assert "join_cap.data_available AS join_data_available" not in compact_query
    assert params == ("24 hours", 7, None)
    assert rows[0]["historical_data_available"] is True
    assert rows[0]["cpu_data_available"] is True
    assert rows[0]["wait_data_available"] is True
    assert rows[0]["predicate_data_available"] is True
    assert rows[0]["join_data_available"] is True
    assert rows[1]["historical_data_available"] is True
    assert rows[1]["cpu_data_available"] is False
    assert rows[1]["wait_data_available"] is False
    assert rows[1]["predicate_data_available"] is False
    assert rows[1]["join_data_available"] is False


def _candidate(
    *, server: int, database: int, query: int, attnums: list[int], columns: list[str]
) -> dict[str, Any]:
    return {
        "candidate_id": uuid4(),
        "server_id": server,
        "server_alias": f"server-{server}",
        "database_id": database,
        "database_name": f"db-{database}",
        "query_id": query,
        "relation_id": 55,
        "schema_name": "public",
        "table_name": "orders",
        "method": "btree",
        "key_attnums": attnums,
        "key_column_names": columns,
        "ordering_rule": "EQUALITY_JOIN_THEN_FILTER",
        "join_occurrences": 10,
        "filter_occurrences": 20,
        "sample_count": 2,
        "observed_from": datetime(2026, 7, 25, tzinfo=timezone.utc),
        "observed_to": datetime(2026, 7, 26, tzinfo=timezone.utc),
        "confidence": "MEDIUM",
    }


@pytest.mark.asyncio
async def test_optimize_groups_exact_order_only_and_preserves_source_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    candidates = [
        _candidate(server=1, database=19, query=101, attnums=[1, 2], columns=["a", "b"]),
        _candidate(server=1, database=19, query=102, attnums=[1, 2], columns=["a", "b"]),
        _candidate(server=1, database=19, query=103, attnums=[2, 1], columns=["b", "a"]),
        _candidate(server=2, database=19, query=104, attnums=[1, 2], columns=["a", "b"]),
    ]
    writes = [
        {"server_id": 1, "database_id": 19, "relation_id": 55, "write_rows": 50, "writes_per_hour": 5.0},
        {"server_id": 2, "database_id": 19, "relation_id": 55, "write_rows": 100, "writes_per_hour": 10.0},
    ]
    fake_pool = _Pool([candidates, writes])
    monkeypatch.setattr(powa_module, "pool", fake_pool)
    repository = PowaRepository()

    async def snapshot(_: str) -> list[dict[str, object]]:
        return [
            {"server_id": 1, "database_id": 19, "query_id": 101, "total_exec_time_ms": 100.0},
            {"server_id": 1, "database_id": 19, "query_id": 102, "total_exec_time_ms": 200.0},
            {"server_id": 1, "database_id": 19, "query_id": 103, "total_exec_time_ms": 50.0},
            {"server_id": 2, "database_id": 19, "query_id": 104, "total_exec_time_ms": 400.0},
        ]

    monkeypatch.setattr(repository, "_query_metrics_snapshot", snapshot)
    rows, total, summary = await repository.database_optimize_rows(
        window="24h", server_id=None, database_id=None,
        page=1, page_size=2, sort_by="affectedLoad",
    )
    assert total == 3
    assert len(rows) == 2
    assert rows[0]["server_id"] == 2
    exact = next(row for row in rows if row["server_id"] == 1 and row["columns"] == ["a", "b"])
    assert exact["affected_query_count"] == 2
    assert exact["affected_load_ms"] == 300.0
    assert summary == {"candidate_groups": 3, "affected_queries": 4, "affected_load_ms": 750.0}


@pytest.mark.asyncio
async def test_optimize_bounds_affected_query_preview_without_losing_exact_totals(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    candidates = [
        _candidate(
            server=1,
            database=19,
            query=query_id,
            attnums=[1, 2],
            columns=["a", "b"],
        )
        for query_id in range(100, 125)
    ]
    fake_pool = _Pool([candidates, []])
    monkeypatch.setattr(powa_module, "pool", fake_pool)
    repository = PowaRepository()

    async def snapshot(_: str) -> list[dict[str, object]]:
        return [
            {
                "server_id": 1,
                "database_id": 19,
                "query_id": query_id,
                "total_exec_time_ms": float(query_id),
            }
            for query_id in range(100, 125)
        ]

    monkeypatch.setattr(repository, "_query_metrics_snapshot", snapshot)
    rows, total, summary = await repository.database_optimize_rows(
        window="24h",
        server_id=1,
        database_id=19,
        page=1,
        page_size=50,
        sort_by="affectedLoad",
    )

    assert total == 1
    assert summary["affected_queries"] == 25
    assert rows[0]["affected_query_count"] == 25
    assert len(rows[0]["affected_query_ids"]) == 20
    assert rows[0]["affected_query_ids"][:3] == ["124", "123", "122"]
    assert rows[0]["representative_query_id"] == "124"


@pytest.mark.asyncio
async def test_optimize_contract_never_fabricates_wal_or_validation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def rows(**_: object):
        return ([{
            "group_id": "g", "server_id": 1, "server_alias": "s",
            "database_id": 2, "database_name": "d", "relation_id": 3,
            "schema_name": "public", "table_name": "orders", "method": "btree",
            "columns": ["a", "b"], "ordering_rules": [], "confidence": "LOW",
            "affected_query_count": 1, "affected_query_ids": ["4"], "affected_load_ms": 10,
            "join_occurrences": 5, "filter_occurrences": 5, "sample_count": 2,
            "observed_from": datetime.now(timezone.utc), "observed_to": datetime.now(timezone.utc),
            "representative_query_id": "4", "representative_candidate_id": str(uuid4()),
            "create_index_sql": "CREATE INDEX CONCURRENTLY ...", "write_rows": 1,
            "writes_per_hour": 1.0, "maintenance_risk": "LOW",
        }], 1, {"candidate_groups": 1, "affected_queries": 1, "affected_load_ms": 10})

    monkeypatch.setattr(router_module.repository, "database_optimize_rows", rows)
    result = await database_optimize(
        window="24h", server_id=None, database_id=None,
        page=1, page_size=50, sort_by="affectedLoad",
    )
    item = result["items"][0]
    assert result["summary"]["validatedGroups"] == 0
    assert item["existingIndex"]["status"] == "NOT_CHECKED"
    assert item["hypopg"]["status"] == "NOT_EVALUATED"
    assert item["representative"]["queryId"] == "4"
    assert item["affectedQueryIds"] == ["4"]
    assert item["maintenanceCost"]["walBytesEstimate"] is None
    assert item["maintenanceCost"]["reason"]


def test_release_contract_reports_expected_migration() -> None:
    payload = _release_payload({
        "current_migration": "0014",
        "applied_count": 14,
        "latest_applied_at": datetime(2026, 7, 26, tzinfo=timezone.utc),
    })
    assert payload["applicationVersion"] == "1.1.0"
    assert payload["migration"]["expected"] == "0014"
    assert payload["migration"]["upToDate"] is True


def test_backend_versions_and_scoped_openapi_contract_are_aligned() -> None:
    assert api_app.version == evaluator_app.version == clone_app.version == "1.1.0"
    schema = api_app.openapi()
    for path in ("/api/v1/system-health", "/api/v1/operations"):
        parameters = {
            parameter["name"] for parameter in schema["paths"][path]["get"]["parameters"]
        }
        assert {"window", "serverId", "databaseId"} <= parameters
