from __future__ import annotations

import logging
import signal
from datetime import datetime, timezone
from threading import Event
from time import monotonic
from typing import Final

import psycopg
from psycopg import Connection, sql
from psycopg.rows import dict_row

from app.config import (
    GLOBAL_TREND_SNAPSHOT_VIEWS,
    QUERY_METRICS_SNAPSHOT_VIEWS,
    Settings,
    get_settings,
)


logger = logging.getLogger("advisor.snapshot_worker")

WINDOW_ORDER: Final[tuple[str, ...]] = ("1h", "24h", "7d", "30d")
QUERY_METRICS_STATE_TABLE: Final = "query_metrics_snapshot_state"
GLOBAL_TREND_STATE_TABLE: Final = "global_trend_snapshot_state"
QUERY_METRICS_LOCK_NAME: Final = (
    "postgresql-advisor:query-metrics-snapshot-refresh"
)
GLOBAL_TREND_LOCK_NAME: Final = "postgresql-advisor:global-trend-snapshot-refresh"


def refresh_intervals(settings: Settings) -> dict[str, int]:
    return {
        "1h": settings.query_metrics_snapshot_1h_refresh_seconds,
        "24h": settings.query_metrics_snapshot_24h_refresh_seconds,
        "7d": settings.query_metrics_snapshot_7d_refresh_seconds,
        "30d": settings.query_metrics_snapshot_30d_refresh_seconds,
    }


def open_connection(settings: Settings) -> Connection[dict[str, object]]:
    connection = psycopg.connect(
        settings.database_conninfo,
        autocommit=True,
        row_factory=dict_row,
        application_name="advisor-dashboard-snapshot-worker",
    )
    connection.execute(
        "SELECT set_config('statement_timeout', %s, false)",
        (f"{settings.query_metrics_snapshot_statement_timeout_seconds}s",),
    )
    return connection


def _set_refreshing(
    connection: Connection[dict[str, object]],
    window: str,
    *,
    state_table: str,
) -> None:
    connection.execute(
        f"""
        UPDATE advisor.{state_table}
           SET status = 'refreshing',
               refresh_started_at = clock_timestamp(),
               last_error = NULL,
               updated_at = clock_timestamp()
         WHERE window_key = %s
        """,
        (window,),
    )


def _set_ready(
    connection: Connection[dict[str, object]],
    window: str,
    *,
    state_table: str,
    duration_ms: int,
    row_count: int,
) -> None:
    connection.execute(
        f"""
        UPDATE advisor.{state_table}
           SET status = 'ready',
               refreshed_at = clock_timestamp(),
               refresh_duration_ms = %s,
               row_count = %s,
               last_error = NULL,
               updated_at = clock_timestamp()
         WHERE window_key = %s
        """,
        (duration_ms, row_count, window),
    )


def _set_failed(
    connection: Connection[dict[str, object]],
    window: str,
    error: BaseException,
    *,
    state_table: str,
) -> None:
    sqlstate = getattr(error, "sqlstate", None)
    diagnostic = type(error).__name__
    if sqlstate:
        diagnostic = f"{diagnostic} (SQLSTATE {sqlstate})"
    connection.execute(
        f"""
        UPDATE advisor.{state_table}
           SET status = 'failed',
               last_error = %s,
               updated_at = clock_timestamp()
         WHERE window_key = %s
        """,
        (diagnostic[:500], window),
    )


def _refresh_snapshot(
    connection: Connection[dict[str, object]],
    window: str,
    *,
    views: dict[str, str],
    state_table: str,
    lock_name: str,
    family: str,
) -> bool:
    view_name = views[window]
    lock_row = connection.execute(
        "SELECT pg_try_advisory_lock(hashtextextended(%s, 0)) AS acquired",
        (lock_name,),
    ).fetchone()
    if not lock_row or not lock_row["acquired"]:
        return False

    started_at = monotonic()
    try:
        _set_refreshing(connection, window, state_table=state_table)
        populated_row = connection.execute(
            """
            SELECT ispopulated
              FROM pg_matviews
             WHERE schemaname = 'advisor'
               AND matviewname = %s
            """,
            (view_name,),
        ).fetchone()
        if populated_row is None:
            raise RuntimeError(f"{family} materialized snapshot is missing")

        concurrently = (
            sql.SQL("CONCURRENTLY ") if populated_row["ispopulated"] else sql.SQL("")
        )
        connection.execute(
            sql.SQL("REFRESH MATERIALIZED VIEW {}{}.{}").format(
                concurrently,
                sql.Identifier("advisor"),
                sql.Identifier(view_name),
            )
        )
        count_row = connection.execute(
            sql.SQL("SELECT count(*) AS row_count FROM {}.{}").format(
                sql.Identifier("advisor"),
                sql.Identifier(view_name),
            )
        ).fetchone()
        duration_ms = max(0, round((monotonic() - started_at) * 1000))
        _set_ready(
            connection,
            window,
            state_table=state_table,
            duration_ms=duration_ms,
            row_count=int(count_row["row_count"]) if count_row else 0,
        )
        logger.info(
            "snapshot ready family=%s window=%s rows=%s duration_ms=%s",
            family,
            window,
            count_row["row_count"] if count_row else 0,
            duration_ms,
        )
        return True
    except BaseException as error:
        try:
            _set_failed(
                connection,
                window,
                error,
                state_table=state_table,
            )
        except Exception:
            logger.exception(
                "could not persist snapshot failure family=%s window=%s",
                family,
                window,
            )
        raise
    finally:
        try:
            connection.execute(
                "SELECT pg_advisory_unlock(hashtextextended(%s, 0))",
                (lock_name,),
            )
        except Exception:
            logger.exception("could not release snapshot advisory lock")


def refresh_snapshot(
    connection: Connection[dict[str, object]],
    window: str,
) -> bool:
    return _refresh_snapshot(
        connection,
        window,
        views=QUERY_METRICS_SNAPSHOT_VIEWS,
        state_table=QUERY_METRICS_STATE_TABLE,
        lock_name=QUERY_METRICS_LOCK_NAME,
        family="query_metrics",
    )


def refresh_global_trend_snapshot(
    connection: Connection[dict[str, object]],
    window: str,
) -> bool:
    return _refresh_snapshot(
        connection,
        window,
        views=GLOBAL_TREND_SNAPSHOT_VIEWS,
        state_table=GLOBAL_TREND_STATE_TABLE,
        lock_name=GLOBAL_TREND_LOCK_NAME,
        family="global_trend",
    )


def _due_windows(
    connection: Connection[dict[str, object]],
    settings: Settings,
    *,
    state_table: str,
    now: datetime | None = None,
) -> list[str]:
    rows = connection.execute(
        f"""
        SELECT window_key, refreshed_at
          FROM advisor.{state_table}
         ORDER BY CASE window_key
                    WHEN '1h' THEN 1
                    WHEN '24h' THEN 2
                    WHEN '7d' THEN 3
                    WHEN '30d' THEN 4
                  END
        """
    ).fetchall()
    refreshed = {str(row["window_key"]): row["refreshed_at"] for row in rows}
    observed_at = now or datetime.now(timezone.utc)
    intervals = refresh_intervals(settings)
    due: list[str] = []
    for window in WINDOW_ORDER:
        refreshed_at = refreshed.get(window)
        if not isinstance(refreshed_at, datetime):
            due.append(window)
            continue
        age_seconds = max(0.0, (observed_at - refreshed_at).total_seconds())
        if age_seconds >= intervals[window]:
            due.append(window)
    return due


def due_windows(
    connection: Connection[dict[str, object]],
    settings: Settings,
    *,
    now: datetime | None = None,
) -> list[str]:
    return _due_windows(
        connection,
        settings,
        state_table=QUERY_METRICS_STATE_TABLE,
        now=now,
    )


def global_trend_due_windows(
    connection: Connection[dict[str, object]],
    settings: Settings,
    *,
    now: datetime | None = None,
) -> list[str]:
    return _due_windows(
        connection,
        settings,
        state_table=GLOBAL_TREND_STATE_TABLE,
        now=now,
    )


def run_worker(settings: Settings, stop: Event) -> None:
    retry_not_before: dict[tuple[str, str], float] = {}
    while not stop.is_set():
        try:
            with open_connection(settings) as connection:
                while not stop.is_set():
                    jobs = [
                        ("query_metrics", window, refresh_snapshot)
                        for window in due_windows(connection, settings)
                    ]
                    jobs.extend(
                        (
                            "global_trend",
                            window,
                            refresh_global_trend_snapshot,
                        )
                        for window in global_trend_due_windows(connection, settings)
                    )
                    attempted = False
                    for family, window, refresh in jobs:
                        if stop.is_set():
                            break
                        retry_key = (family, window)
                        if monotonic() < retry_not_before.get(retry_key, 0):
                            continue
                        attempted = True
                        try:
                            refreshed = refresh(connection, window)
                            if refreshed:
                                retry_not_before.pop(retry_key, None)
                            else:
                                retry_not_before[retry_key] = (
                                    monotonic()
                                    + settings.query_metrics_snapshot_poll_seconds
                                )
                        except Exception:
                            retry_not_before[retry_key] = (
                                monotonic()
                                + settings.query_metrics_snapshot_retry_seconds
                            )
                            logger.exception(
                                "snapshot refresh failed family=%s window=%s",
                                family,
                                window,
                            )
                    if not attempted:
                        stop.wait(settings.query_metrics_snapshot_poll_seconds)
        except Exception:
            logger.exception("snapshot worker connection loop failed")
            stop.wait(settings.query_metrics_snapshot_retry_seconds)


def main() -> None:
    logging.basicConfig(
        level=getattr(logging, get_settings().log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = get_settings()
    stop = Event()

    def request_stop(_: int, __: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    run_worker(settings, stop)


if __name__ == "__main__":
    main()
