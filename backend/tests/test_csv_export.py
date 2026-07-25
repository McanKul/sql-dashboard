from __future__ import annotations

import csv
import io
from typing import Any

import pytest
from fastapi.responses import StreamingResponse

import app.repositories.powa as powa_module
from app.api.router import export_queries
from app.repositories.powa import repository
from app.security import RequestPrincipal


ADMIN_PRINCIPAL = RequestPrincipal(
    credential_id="operator-cli",
    subject="user:operator-1",
    roles=frozenset({"admin"}),
)


class FakeCursor:
    def __init__(self, batches: list[list[dict[str, Any]]]) -> None:
        self.batches = batches
        self.executed_query = ""
        self.executed_params: list[Any] = []
        self.fetch_sizes: list[int] = []

    async def __aenter__(self) -> FakeCursor:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    async def execute(self, query: str, params: list[Any] | tuple[Any, ...]) -> None:
        self.executed_query = query
        self.executed_params = list(params)

    async def fetchmany(self, size: int) -> list[dict[str, Any]]:
        self.fetch_sizes.append(size)
        return self.batches.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.server_cursor = cursor
        self.cursor_name: str | None = None

    async def __aenter__(self) -> FakeConnection:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    def cursor(self, *, name: str | None = None) -> FakeCursor:
        self.cursor_name = name
        return self.server_cursor


class FakePool:
    def __init__(self, connection: FakeConnection) -> None:
        self._connection = connection

    def connection(self) -> FakeConnection:
        return self._connection


def _csv_row(query_id: int, *, sql_text: str | None = None) -> dict[str, Any]:
    return {
        "server_id": 1,
        "database_id": 16_384,
        "query_id": query_id,
        "sql_text": sql_text or f"SELECT {query_id}",
        "calls": query_id + 10,
        "total_exec_time_ms": float(query_id),
        "mean_exec_time_ms": 1.5,
        "cpu_user_time_ms": 1.0,
        "cpu_system_time_ms": 0.25,
        "cpu_total_time_ms": 1.25,
        "cpu_percent_of_exec_time": 83.33,
        "filesystem_reads_bytes": 4096,
        "filesystem_writes_bytes": 0,
        "wait_total_samples": 2,
        "dominant_wait_category": "IO",
        "dominant_wait_event": "DataFileRead",
        "dominant_wait_share_percent": 50.0,
        "impact_score": 80.0,
        "priority": "HIGH",
        "regression_percent": 25.0,
        "review_status": "NEW",
    }


@pytest.mark.asyncio
async def test_repository_export_uses_server_cursor_and_bounded_fetchmany(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor(
        [
            [
                {"query_id": 3},
                {"query_id": 2},
            ],
            [{"query_id": 1}],
            [],
        ]
    )
    connection = FakeConnection(cursor)
    monkeypatch.setattr(powa_module, "pool", FakePool(connection))

    batches = [
        batch
        async for batch in repository.stream_query_rows(
            window="24h",
            search="orders",
            priority="high",
            server_id=4,
            database_id=16_384,
            min_calls=10,
            min_duration_ms=25.5,
            sort_by="calls",
            batch_size=2,
        )
    ]

    assert batches == [
        [{"query_id": 3}, {"query_id": 2}],
        [{"query_id": 1}],
    ]
    assert connection.cursor_name == "advisor_query_csv_export"
    assert cursor.fetch_sizes == [2, 2, 2]
    assert "ORDER BY calls DESC NULLS LAST" in cursor.executed_query
    assert "LIMIT" not in cursor.executed_query
    assert "OFFSET" not in cursor.executed_query
    assert cursor.executed_params == [
        "24 hours",
        10,
        25.5,
        "%orders%",
        "%orders%",
        "HIGH",
        4,
        16_384,
    ]


@pytest.mark.asyncio
async def test_repository_empty_export_yields_no_data_batches(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor([[]])
    monkeypatch.setattr(
        powa_module,
        "pool",
        FakePool(FakeConnection(cursor)),
    )

    batches = [
        batch
        async for batch in repository.stream_query_rows(window="1h", batch_size=50)
    ]

    assert batches == []
    assert cursor.fetch_sizes == [50]


@pytest.mark.asyncio
async def test_export_audit_uses_restricted_database_function(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor([])
    monkeypatch.setattr(
        powa_module,
        "pool",
        FakePool(FakeConnection(cursor)),
    )

    await repository.record_query_export_audit(
        actor="user:operator-1",
        phase="completed",
        details={"window": "24h", "rows": 250},
    )

    assert "advisor.record_query_export_audit" in cursor.executed_query
    assert "INSERT INTO advisor.audit_log" not in cursor.executed_query
    assert cursor.executed_params == [
        "user:operator-1",
        "COMPLETED",
        '{"window": "24h", "rows": 250}',
    ]

    with pytest.raises(ValueError):
        await repository.record_query_export_audit(
            actor="user:operator-1",
            phase="FAILED",
            details={},
        )


@pytest.mark.asyncio
async def test_csv_export_streams_all_filtered_rows_and_audits_before_body(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []
    captured: dict[str, Any] = {}
    rows = [_csv_row(index) for index in range(205)]
    rows[204]["sql_text"] = "SELECT 'comma, and newline\nkept'"

    async def stream_query_rows(**kwargs: Any):
        captured.update(kwargs)
        events.append("cursor-opened")
        try:
            yield rows[:125]
            events.append("second-batch")
            yield rows[125:]
        finally:
            events.append("cursor-closed")

    async def forbidden_query_rows(**_: Any) -> tuple[list[dict[str, Any]], int]:
        raise AssertionError("CSV export paginated query_rows yolunu kullanmamali")

    async def record_query_export_audit(
        *, actor: str, phase: str, details: dict[str, Any]
    ) -> None:
        event = phase.lower()
        events.append(event)
        captured[f"{event}_actor"] = actor
        captured[f"{event}_details"] = details

    monkeypatch.setattr(repository, "stream_query_rows", stream_query_rows)
    monkeypatch.setattr(repository, "query_rows", forbidden_query_rows)
    monkeypatch.setattr(repository, "record_query_export_audit", record_query_export_audit)

    response = await export_queries(
        principal=ADMIN_PRINCIPAL,
        window="7d",
        search="orders",
        priority="critical",
        server_id=7,
        database_id=16_384,
        min_calls=20,
        min_duration_ms=100.5,
        sort_by="totalTime",
    )

    assert isinstance(response, StreamingResponse)
    assert events == ["requested"]
    first_chunk = await anext(response.body_iterator)
    assert events == ["requested"]
    assert str(first_chunk).startswith("server_id,database_id,query_id,sql")

    remaining_chunks = [chunk async for chunk in response.body_iterator]
    body = "".join([str(first_chunk), *[str(chunk) for chunk in remaining_chunks]])
    parsed = list(csv.reader(io.StringIO(body)))

    assert len(parsed) == 206
    assert parsed[-1][2] == "204"
    assert parsed[-1][3] == "SELECT 'comma, and newline\nkept'"
    assert captured["requested_actor"] == "user:operator-1"
    requested_details = captured["requested_details"]
    assert requested_details["credentialId"] == "operator-cli"
    assert requested_details["window"] == "7d"
    assert requested_details["filters"] == {
        "search": "orders",
        "priority": "critical",
        "serverId": 7,
        "databaseId": 16_384,
        "minCalls": 20,
        "minDurationMs": 100.5,
        "sort": "totalTime",
    }
    assert requested_details["exportId"]
    assert captured["completed_actor"] == "user:operator-1"
    assert captured["completed_details"] == {**requested_details, "rows": 205}
    assert captured["window"] == "7d"
    assert captured["search"] == "orders"
    assert captured["priority"] == "critical"
    assert captured["server_id"] == 7
    assert captured["database_id"] == 16_384
    assert captured["min_calls"] == 20
    assert captured["min_duration_ms"] == 100.5
    assert captured["sort_by"] == "totalTime"
    assert "attachment; filename=\"queries-7d.csv\"" == response.headers["content-disposition"]
    assert events == [
        "requested",
        "cursor-opened",
        "second-batch",
        "cursor-closed",
        "completed",
    ]


@pytest.mark.asyncio
async def test_interrupted_csv_keeps_request_audit_without_false_completion(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    events: list[str] = []

    async def stream_query_rows(**_: Any):
        events.append("cursor-opened")
        try:
            yield [_csv_row(1)]
            yield [_csv_row(2)]
        finally:
            events.append("cursor-closed")

    async def audit(*, phase: str, **_: Any) -> None:
        events.append(phase.lower())

    monkeypatch.setattr(repository, "stream_query_rows", stream_query_rows)
    monkeypatch.setattr(repository, "record_query_export_audit", audit)

    response = await export_queries(
        principal=ADMIN_PRINCIPAL,
        window="24h",
        search=None,
        priority=None,
        server_id=None,
        database_id=None,
        min_calls=0,
        min_duration_ms=0,
        sort_by="impact",
    )
    await anext(response.body_iterator)  # CSV header
    await anext(response.body_iterator)  # first database batch
    await response.body_iterator.aclose()

    assert events == ["requested", "cursor-opened", "cursor-closed"]
