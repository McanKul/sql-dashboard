from __future__ import annotations

import asyncio
import logging
from typing import Any

import pytest

import app.api.router as router_module
import app.repositories.powa as powa_module
from app.api.router import queries
from app.repositories.powa import (
    PowaRepository,
    QueryMetricsSnapshotTooLarge,
    _ilike_matcher,
)


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        return self.value


def metric_row(
    query_id: int,
    *,
    sql_text: str | None = None,
    server_id: int = 1,
    database_id: int = 10,
    calls: int = 30,
    total_exec_time_ms: float | None = 100.0,
    impact_score: float | None = 90.0,
    cpu_total_time_ms: float | None = None,
    priority: str = "HIGH",
    regression: bool = False,
    marker: int = 1,
) -> dict[str, Any]:
    return {
        "query_id": query_id,
        "sql_text": sql_text or f"SELECT {query_id}",
        "server_id": server_id,
        "database_id": database_id,
        "calls": calls,
        "total_exec_time_ms": total_exec_time_ms,
        "impact_score": impact_score,
        "cpu_total_time_ms": cpu_total_time_ms,
        "priority": priority,
        "previous_period_available": regression,
        "comparison_reliable": regression,
        "regression_percent": 25.0 if regression else None,
        "previous_calls": 25 if regression else None,
        "nested": {"marker": marker},
    }


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


async def wait_until(predicate: Any) -> None:
    for _ in range(100):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("asynchronous cache condition was not reached")


def test_ilike_wildcards_are_backtracking_safe_and_escape_compatible() -> None:
    assert _ilike_matcher(r"A\_1").fullmatch("prefix a_1 suffix")
    assert not _ilike_matcher(r"A\_1").fullmatch("prefix ax1 suffix")
    assert _ilike_matcher("ord%item_").fullmatch("prefix ORDER-item7 suffix")
    # Preserve PostgreSQL's one-character `_` width and common Unicode lower
    # semantics instead of casefold expansions (`ß` -> `ss`, sigma folding).
    assert _ilike_matcher("x_y").fullmatch("xßy")
    assert not _ilike_matcher("STRASSE").fullmatch("straße")
    assert not _ilike_matcher("ς").fullmatch("Σ")

    adversarial = "%_" * 149 + "z"
    assert not _ilike_matcher(adversarial).fullmatch("a" * 100_000)


def test_cache_cannot_disable_singleflight_repository_protection() -> None:
    with pytest.raises(ValueError, match="entry siniri"):
        PowaRepository(query_list_cache_max_entries=0)


@pytest.mark.asyncio
async def test_complete_window_snapshot_is_reused_for_all_query_arguments(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads: list[str] = []
    source_rows = [
        metric_row(
            1,
            sql_text="SELECT * FROM orders WHERE code = 'A_1'",
            regression=True,
        ),
        metric_row(
            2,
            sql_text="select customer",
            server_id=2,
            database_id=20,
            calls=5,
            total_exec_time_ms=10,
            impact_score=80,
            priority="LOW",
        ),
        metric_row(
            3,
            sql_text="SELECT orderX",
            calls=50,
            total_exec_time_ms=200,
            impact_score=90,
            cpu_total_time_ms=50,
        ),
        metric_row(4, total_exec_time_ms=None, impact_score=None),
    ]

    async def load(window: str) -> list[dict[str, Any]]:
        loads.append(window)
        return source_rows

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)

    first, total = await repository.query_rows(window="1h", page_size=1)
    second, second_total = await repository.query_rows(window="1h", page=2, page_size=1)
    searched, searched_total = await repository.query_rows(
        window="1h", search=r"A\_1", priority="high"
    )
    scoped, scoped_total = await repository.query_rows(
        window="1h",
        server_id=2,
        database_id=20,
        min_calls=5,
        min_duration_ms=10,
    )
    sorted_rows, sorted_total = await repository.query_rows(
        window="1h", min_calls=30, min_duration_ms=50, sort_by="calls"
    )
    regressions, regression_total = await repository.query_rows(
        window="1h", regressions_only=True, sort_by="regression"
    )
    out_of_range, out_of_range_total = await repository.query_rows(
        window="1h", page=99, page_size=50
    )

    assert loads == ["1h"]
    assert ([row["query_id"] for row in first], total) == ([1], 3)
    assert ([row["query_id"] for row in second], second_total) == ([3], 3)
    assert ([row["query_id"] for row in searched], searched_total) == ([1], 1)
    assert ([row["query_id"] for row in scoped], scoped_total) == ([2], 1)
    assert ([row["query_id"] for row in sorted_rows], sorted_total) == ([3, 1], 2)
    assert ([row["query_id"] for row in regressions], regression_total) == ([1], 1)
    assert out_of_range == []
    assert out_of_range_total == 3


@pytest.mark.asyncio
async def test_sort_is_descending_with_query_id_ties_and_nulls_last(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())

    async def load(_: str) -> list[dict[str, Any]]:
        return [
            metric_row(8, impact_score=None),
            metric_row(5, impact_score=90),
            metric_row(2, impact_score=90),
            metric_row(3, impact_score=100),
            metric_row(7, impact_score=None),
        ]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    rows, total = await repository.query_rows(window="1h", sort_by="impact")

    assert total == 5
    assert [row["query_id"] for row in rows] == [3, 2, 5, 7, 8]


@pytest.mark.asyncio
async def test_cached_pages_are_deep_copy_safe(monkeypatch: pytest.MonkeyPatch) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        return [metric_row(1, marker=7)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)

    first, _ = await repository.query_rows(window="1h")
    first[0].pop("query_id")
    first[0]["nested"]["marker"] = 999
    second, _ = await repository.query_rows(window="1h")

    assert loads == 1
    assert second[0]["query_id"] == 1
    assert second[0]["nested"] == {"marker": 7}


@pytest.mark.asyncio
async def test_overview_and_detail_share_snapshot_with_list(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    loads = 0
    rows = [
        metric_row(
            1,
            total_exec_time_ms=100,
            impact_score=50,
            priority="CRITICAL",
            regression=True,
        ),
        metric_row(
            1,
            server_id=2,
            database_id=20,
            total_exec_time_ms=200,
            impact_score=80,
            priority="LOW",
        ),
        metric_row(3, total_exec_time_ms=None, impact_score=10, priority="CRITICAL"),
    ]

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        return rows

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)

    await repository.query_rows(window="1h")
    summary = await repository.overview_summary(window="1h")
    detail = await repository.query_by_id(query_id=1, window="1h")
    scoped = await repository.query_by_id(
        query_id=1, window="1h", server_id=1, database_id=10
    )

    assert loads == 1
    assert summary == {
        "total_db_time_ms": 300.0,
        "tracked_queries": 3,
        "critical_queries": 2,
        "regressions": 1,
    }
    assert detail is not None and detail["server_id"] == 2
    assert scoped is not None and scoped["server_id"] == 1
    detail["nested"]["marker"] = 999
    scoped_again = await repository.query_by_id(
        query_id=1, window="1h", server_id=1, database_id=10
    )
    assert scoped_again is not None and scoped_again["nested"]["marker"] == 1


@pytest.mark.asyncio
async def test_identical_cold_misses_share_one_refresh(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    started = asyncio.Event()
    release = asyncio.Event()
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        started.set()
        await release.wait()
        return [metric_row(1)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)

    first = asyncio.create_task(repository.query_rows(window="1h"))
    await started.wait()
    second = asyncio.create_task(repository.query_rows(window="1h"))
    await asyncio.sleep(0)
    assert loads == 1

    release.set()
    first_result, second_result = await asyncio.gather(first, second)
    assert first_result == second_result
    assert first_result[0] is not second_result[0]


@pytest.mark.asyncio
async def test_different_windows_do_not_scan_repository_concurrently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    first_started = asyncio.Event()
    first_release = asyncio.Event()
    started_windows: list[str] = []

    async def load(window: str) -> list[dict[str, Any]]:
        started_windows.append(window)
        if window == "1h":
            first_started.set()
            await first_release.wait()
        return [metric_row(1)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    first = asyncio.create_task(repository.query_rows(window="1h"))
    await first_started.wait()
    second = asyncio.create_task(repository.query_rows(window="24h"))
    await asyncio.sleep(0)
    assert started_windows == ["1h"]

    first_release.set()
    await asyncio.gather(first, second)
    assert started_windows == ["1h", "24h"]


@pytest.mark.asyncio
async def test_stale_snapshot_returns_immediately_and_refreshes_once(
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
            return [metric_row(1, marker=1)]
        refresh_started.set()
        await refresh_release.wait()
        return [metric_row(1, marker=2)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    await repository.query_rows(window="1h")
    clock.value = 61

    stale, _ = await asyncio.wait_for(repository.query_rows(window="1h"), timeout=0.1)
    await refresh_started.wait()
    stale_again, _ = await asyncio.wait_for(
        repository.query_rows(window="1h"), timeout=0.1
    )
    assert stale[0]["nested"]["marker"] == 1
    assert stale_again[0]["nested"]["marker"] == 1
    assert loads == 2

    refresh_release.set()
    await wait_until(lambda: not repository._query_metrics_refresh_tasks)
    refreshed, _ = await repository.query_rows(window="1h")
    assert refreshed[0]["nested"]["marker"] == 2
    assert loads == 2


@pytest.mark.asyncio
async def test_background_failure_retains_stale_and_is_observed(
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads = 0
    fail = True
    loop_errors: list[dict[str, Any]] = []
    loop = asyncio.get_running_loop()
    previous_handler = loop.get_exception_handler()
    loop.set_exception_handler(lambda _loop, context: loop_errors.append(context))

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            return [metric_row(1, marker=1)]
        if fail:
            raise RuntimeError("repository unavailable")
        return [metric_row(1, marker=2)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    try:
        await repository.query_rows(window="1h")
        clock.value = 61
        with caplog.at_level(logging.WARNING):
            stale, _ = await repository.query_rows(window="1h")
            await wait_until(lambda: not repository._query_metrics_refresh_tasks)
            await asyncio.sleep(0)

        assert stale[0]["nested"]["marker"] == 1
        assert repository._query_metrics_cache["1h"].rows[0]["nested"]["marker"] == 1
        assert loop_errors == []
        assert "RuntimeError" in caplog.text

        fail = False
        # The first failed refresh applies a one-second bounded backoff so
        # high request rate cannot create a repository retry storm.
        clock.value = 62.1
        stale_retry, _ = await repository.query_rows(window="1h")
        assert stale_retry[0]["nested"]["marker"] == 1
        await wait_until(lambda: not repository._query_metrics_refresh_tasks)
        fresh, _ = await repository.query_rows(window="1h")
        assert fresh[0]["nested"]["marker"] == 2
    finally:
        loop.set_exception_handler(previous_handler)
        await repository.close_query_rows_cache()


@pytest.mark.asyncio
async def test_refresh_failure_backoff_serves_stale_without_retry_storm(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            return [metric_row(1)]
        raise RuntimeError("persistent repository failure")

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    await repository.query_rows(window="1h")
    clock.value = 61
    await repository.query_rows(window="1h")
    await wait_until(lambda: not repository._query_metrics_refresh_tasks)

    for _ in range(20):
        stale, _ = await repository.query_rows(window="1h")
        assert stale[0]["query_id"] == 1
    assert loads == 2

    clock.value = 62.1
    await repository.query_rows(window="1h")
    await wait_until(lambda: not repository._query_metrics_refresh_tasks)
    assert loads == 3
    await repository.close_query_rows_cache()


@pytest.mark.asyncio
async def test_too_old_snapshot_waits_for_refresh(monkeypatch: pytest.MonkeyPatch) -> None:
    clock = FakeClock()
    repository = cache_repository(clock, fresh=10, stale=20)
    release = asyncio.Event()
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            return [metric_row(1, marker=1)]
        await release.wait()
        return [metric_row(1, marker=2)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    await repository.query_rows(window="1h")
    clock.value = 21

    pending = asyncio.create_task(repository.query_rows(window="1h"))
    await asyncio.sleep(0)
    assert not pending.done()
    release.set()
    rows, _ = await pending
    assert rows[0]["nested"]["marker"] == 2


@pytest.mark.asyncio
async def test_window_cache_is_lru_bounded_and_invalidation_blocks_old_repopulation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock, entries=2)
    loads: list[str] = []

    async def load(window: str) -> list[dict[str, Any]]:
        loads.append(window)
        return [metric_row(len(loads), marker=len(loads))]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    await repository.query_rows(window="1h")
    await repository.query_rows(window="24h")
    await repository.query_rows(window="1h")
    await repository.query_rows(window="7d")

    assert list(repository._query_metrics_cache) == ["1h", "7d"]
    await repository.invalidate_query_rows_cache()
    assert not repository._query_metrics_cache
    await repository.query_rows(window="1h")
    assert loads == ["1h", "24h", "7d", "1h"]


@pytest.mark.asyncio
async def test_invalidation_generation_rejects_in_flight_old_snapshot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = cache_repository(FakeClock())
    started = asyncio.Event()
    release = asyncio.Event()
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        if loads == 1:
            started.set()
            await release.wait()
            return [metric_row(1, marker=1)]
        return [metric_row(1, marker=2)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    old_request = asyncio.create_task(repository.query_rows(window="1h"))
    await started.wait()
    await repository.invalidate_query_rows_cache()
    release.set()
    old_rows, _ = await old_request

    assert old_rows[0]["nested"]["marker"] == 1
    assert "1h" not in repository._query_metrics_cache
    new_rows, _ = await repository.query_rows(window="1h")
    assert new_rows[0]["nested"]["marker"] == 2
    assert loads == 2


@pytest.mark.asyncio
async def test_snapshot_row_cap_fails_without_caching_partial_data(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repository = PowaRepository(
        query_list_cache_fresh_seconds=60,
        query_list_cache_stale_seconds=300,
        query_list_cache_max_entries=4,
        query_list_cache_max_rows=2,
    )

    async def load(_: str) -> list[dict[str, Any]]:
        return [metric_row(1), metric_row(2), metric_row(3)]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)

    with pytest.raises(QueryMetricsSnapshotTooLarge):
        await repository.query_rows(window="1h")
    assert not repository._query_metrics_cache
    assert not repository._query_metrics_refresh_tasks


@pytest.mark.asyncio
async def test_snapshot_loader_uses_tagged_bounded_query(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Cursor:
        def __init__(self) -> None:
            self.query = ""
            self.params: tuple[str] = ("",)
            self.fetch_sizes: list[int] = []
            self.batches = [
                [
                    {**metric_row(1), "_cache_row_bytes": 128},
                    {**metric_row(2), "_cache_row_bytes": 128},
                ],
                [{**metric_row(3), "_cache_row_bytes": 128}],
            ]

        async def __aenter__(self) -> Cursor:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        async def execute(self, query: str, params: tuple[str]) -> None:
            self.query = query
            self.params = params

        async def fetchmany(self, size: int) -> list[dict[str, Any]]:
            self.fetch_sizes.append(size)
            return self.batches.pop(0)

    class ControlCursor:
        def __init__(self) -> None:
            self.query = ""

        async def __aenter__(self) -> ControlCursor:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        async def execute(self, query: str) -> None:
            self.query = query

    class Connection:
        def __init__(self, cursor: Cursor) -> None:
            self.cache_cursor = cursor
            self.control_cursor = ControlCursor()
            self.cursor_names: list[str | None] = []

        async def __aenter__(self) -> Connection:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        def cursor(self, *, name: str | None = None) -> Cursor | ControlCursor:
            self.cursor_names.append(name)
            if name is None:
                return self.control_cursor
            return self.cache_cursor

    class Pool:
        def __init__(self, connection: Connection) -> None:
            self.cache_connection = connection

        def connection(self) -> Connection:
            return self.cache_connection

    repository = PowaRepository(
        query_list_cache_fresh_seconds=60,
        query_list_cache_stale_seconds=300,
        query_list_cache_max_entries=4,
        query_list_cache_max_rows=2,
    )
    cursor = Cursor()
    connection = Connection(cursor)
    monkeypatch.setattr(powa_module, "pool", Pool(connection))

    with pytest.raises(QueryMetricsSnapshotTooLarge):
        await repository._load_query_metrics_snapshot("1h")

    assert connection.cursor_names == [None, "advisor_query_metrics_cache_refresh"]
    assert "SET LOCAL application_name" in connection.control_cursor.query
    assert "advisor-query-metrics-cache-refresh" in cursor.query
    assert "pg_column_size(metrics)" in cursor.query
    assert "LIMIT %s" in cursor.query
    assert cursor.params == ("1 hour", 3)
    assert cursor.fetch_sizes == [3, 1]


@pytest.mark.asyncio
async def test_snapshot_loader_byte_cap_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class Cursor:
        async def __aenter__(self) -> Cursor:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        async def execute(self, *_: object) -> None:
            return None

        async def fetchmany(self, _size: int) -> list[dict[str, Any]]:
            return [
                {
                    **metric_row(1),
                    "_cache_row_bytes": 1024 * 1024 + 1,
                }
            ]

    class Connection:
        async def __aenter__(self) -> Connection:
            return self

        async def __aexit__(self, *_: object) -> None:
            return None

        def cursor(self, **_: object) -> Cursor:
            return Cursor()

    class Pool:
        def connection(self) -> Connection:
            return Connection()

    repository = PowaRepository(query_list_cache_max_bytes=1024 * 1024)
    monkeypatch.setattr(powa_module, "pool", Pool())

    with pytest.raises(QueryMetricsSnapshotTooLarge, match="byte limitini"):
        await repository._load_query_metrics_snapshot("1h")


@pytest.mark.asyncio
async def test_cached_raw_sql_is_serialized_per_request_role(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = FakeClock()
    repository = cache_repository(clock)
    loads = 0

    async def load(_: str) -> list[dict[str, Any]]:
        nonlocal loads
        loads += 1
        return [metric_row(1, sql_text="SELECT secret_column FROM private_orders")]

    monkeypatch.setattr(repository, "_load_query_metrics_snapshot", load)
    monkeypatch.setattr(router_module, "repository", repository)

    arguments = {
        "window": "1h",
        "page": 1,
        "page_size": 50,
        "search": None,
        "priority": None,
        "server_id": None,
        "database_id": None,
        "min_calls": 0,
        "min_duration_ms": 0,
        "sort_by": "impact",
    }
    viewer = await queries(role="viewer", **arguments)
    analyst = await queries(role="analyst", **arguments)

    assert loads == 1
    assert "secret_column" not in viewer["items"][0]["sql"]
    assert analyst["items"][0]["sql"] == "SELECT secret_column FROM private_orders"
