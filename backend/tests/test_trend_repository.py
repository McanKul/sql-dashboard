from __future__ import annotations

from typing import Any

import pytest

import app.repositories.powa as powa_module
from app.repositories.powa import PowaRepository


class FakeCursor:
    def __init__(self) -> None:
        self.executions: list[tuple[str, list[Any]]] = []

    async def __aenter__(self) -> FakeCursor:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    async def execute(self, query: str, params: list[Any]) -> None:
        self.executions.append((query, list(params)))

    async def fetchall(self) -> list[dict[str, Any]]:
        return [
            {
                "timestamp": "2026-07-26T00:00:00Z",
                "total_exec_time_ms": 12.5,
                "calls": 3,
            }
        ]


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self._cursor = cursor

    async def __aenter__(self) -> FakeConnection:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    def cursor(self) -> FakeCursor:
        return self._cursor


class FakePool:
    def __init__(self, cursor: FakeCursor) -> None:
        self._connection = FakeConnection(cursor)

    def connection(self) -> FakeConnection:
        return self._connection


@pytest.mark.asyncio
async def test_global_trend_reads_precomputed_fleet_snapshot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor()
    monkeypatch.setattr(powa_module, "pool", FakePool(cursor))
    repository = PowaRepository()

    rows = await repository.trend(window="1h")

    assert rows[0]["calls"] == 3
    tag_query, tag_params = cursor.executions[0]
    assert "SET LOCAL application_name" in tag_query
    assert "advisor-global-trend-snapshot-read" in tag_query
    assert tag_params == []
    query, params = cursor.executions[1]
    assert "advisor.global_trend_snapshot_1h" in query
    assert "advisor.query_trend(" not in query
    assert "advisor-global-trend-snapshot-read" in query
    assert params == [None, None, 100_001]


@pytest.mark.asyncio
async def test_query_trend_pushes_complete_scope_into_five_argument_helper(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor()
    monkeypatch.setattr(powa_module, "pool", FakePool(cursor))
    repository = PowaRepository()

    await repository.trend(
        window="24h",
        server_id=7,
        database_id=16_384,
        query_id=-42,
    )

    query, params = cursor.executions[0]
    assert (
        "advisor.query_trend("
        "now() - %s::interval, %s::interval, %s, %s, %s)" in query
    )
    assert params == ["24 hours", "1 hour", 7, 16_384, -42]


@pytest.mark.asyncio
async def test_server_trend_reads_precomputed_server_scope(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cursor = FakeCursor()
    monkeypatch.setattr(powa_module, "pool", FakePool(cursor))
    repository = PowaRepository()

    await repository.trend(window="1h", server_id=7)

    tag_query, tag_params = cursor.executions[0]
    assert "advisor-global-trend-snapshot-read" in tag_query
    assert tag_params == []
    query, params = cursor.executions[1]
    assert "advisor.global_trend_snapshot_1h" in query
    assert "advisor.query_trend(" not in query
    assert params == [7, None, 100_001]


@pytest.mark.asyncio
async def test_trend_rejects_database_without_server() -> None:
    repository = PowaRepository()

    with pytest.raises(ValueError, match="server_id"):
        await repository.trend(window="1h", database_id=16_384)
