from __future__ import annotations

import asyncio
import logging
from typing import Any

import pytest

import app.repositories.powa as powa_module
from app.repositories.powa import PowaRepository


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        return self.value


def cache_repository(
    clock: FakeClock,
    *,
    fresh: float = 60.0,
    stale: float = 300.0,
    entries: int = 4,
) -> PowaRepository:
    return PowaRepository(
        query_list_cache_fresh_seconds=fresh,
        query_list_cache_stale_seconds=stale,
        query_list_cache_max_entries=entries,
        clock=clock,
    )


def trend_row(marker: int) -> dict[str, Any]:
    return {
        "timestamp": "2026-07-26T00:00:00Z",
        "total_exec_time_ms": float(marker),
        "calls": marker,
        "nested": {"marker": marker},
    }


def metric_row(marker: int) -> dict[str, Any]:
    return {
        "query_id": marker,
        "server_id": 1,
        "database_id": 10,
        "calls": 1,
        "total_exec_time_ms": 1.0,
        "impact_score": 1.0,
        "priority": "LOW",
    }


async def wait_until(predicate: Any) -> None:
    for _ in range(100):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("asynchronous cache condition was not reached")


@pytest.mark.asyncio
async def test_global_trend_cold_singleflight_is_shielded_and_deep_copy_safe(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    started = asyncio.Event()
    release = asyncio.Event()
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        started.set()
        await release.wait()
        return [trend_row(1)]

    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load)

    cancelled_request = asyncio.create_task(repository.trend(window="24h"))
    await started.wait()
    surviving_request = asyncio.create_task(repository.trend(window="24h"))
    await asyncio.sleep(0)
    assert loads == 1

    cancelled_request.cancel()
    with pytest.raises(asyncio.CancelledError):
        await cancelled_request
    assert repository._global_trend_refresh_tasks

    release.set()
    surviving = await surviving_request
    surviving[0]["nested"]["marker"] = 999
    fresh = await repository.trend(window="24h")

    assert loads == 1
    assert fresh[0]["nested"] == {"marker": 1}
    assert fresh[0] is not surviving[0]


@pytest.mark.asyncio
async def test_global_trend_stale_returns_immediately_and_refreshes_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    refresh_started = asyncio.Event()
    refresh_release = asyncio.Event()
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            return [trend_row(1)]
        refresh_started.set()
        await refresh_release.wait()
        return [trend_row(2)]

    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load)
    await repository.trend(window="24h")
    clock.value = 61

    stale = await asyncio.wait_for(repository.trend(window="24h"), timeout=0.1)
    await refresh_started.wait()
    stale_again = await asyncio.wait_for(
        repository.trend(window="24h"), timeout=0.1
    )

    assert stale[0]["nested"]["marker"] == 1
    assert stale_again[0]["nested"]["marker"] == 1
    assert stale[0] is not stale_again[0]
    assert loads == 2

    refresh_release.set()
    await wait_until(lambda: not repository._global_trend_refresh_tasks)
    refreshed = await repository.trend(window="24h")
    assert refreshed[0]["nested"]["marker"] == 2
    assert loads == 2


@pytest.mark.asyncio
async def test_global_trend_failure_backoff_serves_stale_without_retry_storm(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            return [trend_row(1)]
        raise RuntimeError("repository unavailable")

    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load)
    await repository.trend(window="24h")
    clock.value = 61

    with caplog.at_level(logging.WARNING):
        stale = await repository.trend(window="24h")
        await wait_until(lambda: not repository._global_trend_refresh_tasks)
        await asyncio.sleep(0)
    assert stale[0]["calls"] == 1
    assert loads == 2
    assert "RuntimeError" in caplog.text

    for _ in range(20):
        assert (await repository.trend(window="24h"))[0]["calls"] == 1
    assert loads == 2

    clock.value = 62.1
    await repository.trend(window="24h")
    await wait_until(lambda: not repository._global_trend_refresh_tasks)
    assert loads == 3
    retry = repository._global_trend_retry["24h"]
    assert retry.failures == 2
    assert retry.retry_not_before == pytest.approx(64.1)
    await repository.close_query_rows_cache()


@pytest.mark.asyncio
async def test_query_metrics_and_global_trend_share_repository_refresh_lock(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    metrics_started = asyncio.Event()
    metrics_release = asyncio.Event()
    trend_started = asyncio.Event()

    async def load_metrics(_: str) -> list[dict[str, Any]]:
        metrics_started.set()
        await metrics_release.wait()
        return [metric_row(1)]

    async def load_trend(_: str) -> list[dict[str, Any]]:
        trend_started.set()
        return [trend_row(1)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load_metrics)
    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load_trend)

    metrics_request = asyncio.create_task(repository.query_rows(window="24h"))
    await metrics_started.wait()
    trend_request = asyncio.create_task(repository.trend(window="24h"))
    await asyncio.sleep(0)
    assert not trend_started.is_set()
    assert repository._query_metrics_refresh_lock is repository._repository_refresh_lock

    metrics_release.set()
    await asyncio.gather(metrics_request, trend_request)
    assert trend_started.is_set()


@pytest.mark.asyncio
async def test_scoped_trend_bypasses_global_cache(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Cursor:
        def __init__(self) -> None:
            self.executions: list[tuple[str, list[Any]]] = []

        async def __aenter__(self) -> Cursor:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        async def execute(self, query: str, params: list[Any]) -> None:
            self.executions.append((query, list(params)))

        async def fetchall(self) -> list[dict[str, Any]]:
            return [trend_row(len(self.executions))]

    class Connection:
        def __init__(self, cursor: Cursor) -> None:
            self.cursor_instance = cursor

        async def __aenter__(self) -> Connection:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        def cursor(self) -> Cursor:
            return self.cursor_instance

    class Pool:
        def __init__(self, cursor: Cursor) -> None:
            self.connection_instance = Connection(cursor)

        def connection(self) -> Connection:
            return self.connection_instance

    async def fail_if_global(_: str) -> list[dict[str, Any]]:
        raise AssertionError("scoped trend entered the global cache")

    cursor = Cursor()
    repository = cache_repository(FakeClock())
    monkeypatch.setattr(powa_module, "pool", Pool(cursor))
    monkeypatch.setattr(repository, "_load_global_trend_snapshot", fail_if_global)

    for _ in range(2):
        await repository.trend(
            window="24h",
            server_id=7,
            database_id=16_384,
            query_id=-42,
        )

    assert len(cursor.executions) == 2
    assert all("%s, %s, %s)" in query for query, _ in cursor.executions)
    assert all(
        params == ["24 hours", "1 hour", 7, 16_384, -42]
        for _, params in cursor.executions
    )
    assert not repository._global_trend_cache
    assert not repository._global_trend_refresh_tasks


@pytest.mark.asyncio
async def test_invalidation_clears_both_caches_and_blocks_old_trend_repopulation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    trend_started = asyncio.Event()
    trend_release = asyncio.Event()
    trend_loads = 0

    async def load_metrics(_: str) -> list[dict[str, Any]]:
        return [metric_row(1)]

    async def load_trend(_: str) -> list[dict[str, Any]]:
        nonlocal trend_loads
        trend_loads += 1
        if trend_loads == 1:
            trend_started.set()
            await trend_release.wait()
        return [trend_row(trend_loads)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load_metrics)
    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load_trend)
    await repository.query_rows(window="24h")
    old_request = asyncio.create_task(repository.trend(window="24h"))
    await trend_started.wait()

    await repository.invalidate_query_rows_cache()
    assert not repository._query_metrics_cache
    assert not repository._global_trend_cache
    assert not repository._query_metrics_retry
    assert not repository._global_trend_retry

    trend_release.set()
    old_rows = await old_request
    assert old_rows[0]["calls"] == 1
    assert "24h" not in repository._global_trend_cache

    new_rows = await repository.trend(window="24h")
    assert new_rows[0]["calls"] == 2
    assert trend_loads == 2


@pytest.mark.asyncio
async def test_close_cancels_running_and_queued_refresh_tasks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    metrics_started = asyncio.Event()
    never_release = asyncio.Event()

    async def load_metrics(_: str) -> list[dict[str, Any]]:
        metrics_started.set()
        await never_release.wait()
        return [metric_row(1)]

    async def load_trend(_: str) -> list[dict[str, Any]]:
        await never_release.wait()
        return [trend_row(1)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load_metrics)
    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load_trend)

    metrics_request = asyncio.create_task(repository.query_rows(window="24h"))
    await metrics_started.wait()
    trend_request = asyncio.create_task(repository.trend(window="24h"))
    await wait_until(lambda: bool(repository._global_trend_refresh_tasks))

    await repository.close_query_rows_cache()
    results = await asyncio.gather(
        metrics_request,
        trend_request,
        return_exceptions=True,
    )

    assert all(isinstance(result, asyncio.CancelledError) for result in results)
    assert not repository._query_metrics_refresh_tasks
    assert not repository._global_trend_refresh_tasks
    assert not repository._query_metrics_cache
    assert not repository._global_trend_cache


@pytest.mark.asyncio
async def test_global_trend_cache_is_lru_bounded(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock(), entries=2)
    loads: list[str] = []

    async def load(window: str) -> list[dict[str, Any]]:
        loads.append(window)
        return [trend_row(len(loads))]

    monkeypatch.setattr(repository, "_load_global_trend_snapshot", load)
    await repository.trend(window="1h")
    await repository.trend(window="24h")
    await repository.trend(window="1h")
    await repository.trend(window="7d")

    assert list(repository._global_trend_cache) == ["1h", "7d"]
    assert loads == ["1h", "24h", "7d"]
