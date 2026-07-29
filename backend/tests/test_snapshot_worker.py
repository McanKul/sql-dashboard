from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from app.config import (
    GLOBAL_TREND_SNAPSHOT_VIEWS,
    QUERY_METRICS_SNAPSHOT_VIEWS,
    Settings,
    WINDOW_INTERVALS,
)
from app.snapshot_worker import (
    WINDOW_ORDER,
    due_windows,
    global_trend_due_windows,
    refresh_intervals,
)


class Result:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows


class Connection:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows

    def execute(self, _: str) -> Result:
        return Result(self.rows)


def test_snapshot_view_mapping_covers_every_supported_window() -> None:
    assert tuple(QUERY_METRICS_SNAPSHOT_VIEWS) == WINDOW_ORDER
    assert tuple(GLOBAL_TREND_SNAPSHOT_VIEWS) == WINDOW_ORDER
    assert set(QUERY_METRICS_SNAPSHOT_VIEWS) == set(WINDOW_INTERVALS)
    assert set(GLOBAL_TREND_SNAPSHOT_VIEWS) == set(WINDOW_INTERVALS)


def test_due_windows_prioritize_short_windows_and_respect_cadence() -> None:
    observed_at = datetime(2026, 7, 30, 12, tzinfo=timezone.utc)
    settings = Settings(
        query_metrics_snapshot_1h_refresh_seconds=15 * 60,
        query_metrics_snapshot_24h_refresh_seconds=60 * 60,
        query_metrics_snapshot_7d_refresh_seconds=6 * 60 * 60,
        query_metrics_snapshot_30d_refresh_seconds=12 * 60 * 60,
    )
    connection = Connection(
        [
            {
                "window_key": "1h",
                "refreshed_at": observed_at - timedelta(minutes=20),
            },
            {
                "window_key": "24h",
                "refreshed_at": observed_at - timedelta(minutes=30),
            },
            {"window_key": "7d", "refreshed_at": None},
            {
                "window_key": "30d",
                "refreshed_at": observed_at - timedelta(hours=1),
            },
        ]
    )

    assert due_windows(connection, settings, now=observed_at) == ["1h", "7d"]
    assert global_trend_due_windows(
        connection, settings, now=observed_at
    ) == ["1h", "7d"]
    assert refresh_intervals(settings) == {
        "1h": 900,
        "24h": 3600,
        "7d": 21600,
        "30d": 43200,
    }
