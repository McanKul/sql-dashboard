from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from unittest import mock
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MODULE_PATH = Path(__file__).with_name("snapshotter.py")
SPEC = importlib.util.spec_from_file_location("join_snapshotter", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
snapshotter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = snapshotter
SPEC.loader.exec_module(snapshotter)


class FakeResult:
    def __init__(self, *, one: dict[str, Any] | None = None, all_rows: list[dict[str, Any]] | None = None):
        self.one = one
        self.all_rows = all_rows or []

    def fetchone(self) -> dict[str, Any] | None:
        return self.one

    def fetchall(self) -> list[dict[str, Any]]:
        return self.all_rows


class FakeTransaction:
    def __init__(self, events: list[str], name: str):
        self.events = events
        self.name = name

    def __enter__(self) -> None:
        self.events.append(f"{self.name}:begin")

    def __exit__(self, exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.events.append(f"{self.name}:{'rollback' if exc_type else 'commit'}")


class FakeConnection:
    def __init__(self, events: list[str], name: str, result: FakeResult | Exception):
        self.events = events
        self.name = name
        self.result = result
        self.queries: list[tuple[str, tuple[Any, ...]]] = []

    def __enter__(self) -> FakeConnection:
        self.events.append(f"{self.name}:open")
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.events.append(f"{self.name}:close")

    def transaction(self) -> FakeTransaction:
        return FakeTransaction(self.events, self.name)

    def execute(self, query: str, params: tuple[Any, ...] = ()) -> FakeResult:
        self.events.append(f"{self.name}:execute")
        self.queries.append((query, params))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class SequencedFakeConnection(FakeConnection):
    def __init__(
        self,
        events: list[str],
        name: str,
        results: list[FakeResult | Exception],
    ):
        super().__init__(events, name, results[0])
        self.results = list(results)

    def execute(self, _query: str, _params: tuple[Any, ...] = ()) -> FakeResult:
        self.events.append(f"{self.name}:execute")
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def batch() -> Any:
    return snapshotter.Batch(
        batch_id=7,
        captured_at=datetime(2026, 7, 25, tzinfo=timezone.utc),
        rows=[{"queryid": -42, "isJoin": True}],
    )


def settings() -> Any:
    return snapshotter.Settings(
        source_alias="test-source",
        source_database_url="source-url",
        repository_database_url="repository-url",
        poll_interval_seconds=2.0,
        max_backoff_seconds=60.0,
        batch_limit=20,
        connect_timeout_seconds=5,
        statement_timeout_ms=30_000,
        retention_days=30,
        purge_interval_seconds=3_600.0,
    )


class SnapshotterTests(unittest.TestCase):
    def test_ack_happens_only_after_repository_commit(self) -> None:
        events: list[str] = []
        repository = FakeConnection(events, "repository", FakeResult(one={"inserted": True}))
        source = FakeConnection(events, "source", FakeResult(one={"acknowledged": True}))

        result = snapshotter.transfer_batch(
            source, repository, source_alias="test-source", batch=batch()
        )

        self.assertEqual(result, (True, True))
        self.assertLess(events.index("repository:commit"), events.index("source:execute"))

    def test_repository_failure_leaves_source_batch_unacknowledged(self) -> None:
        events: list[str] = []
        repository = FakeConnection(events, "repository", RuntimeError("do not expose me"))
        source = FakeConnection(events, "source", FakeResult(one={"acknowledged": True}))

        with self.assertRaises(RuntimeError):
            snapshotter.transfer_batch(
                source, repository, source_alias="test-source", batch=batch()
            )

        self.assertNotIn("source:execute", events)
        self.assertIn("repository:rollback", events)

    def test_duplicate_repository_batch_is_still_acknowledged(self) -> None:
        events: list[str] = []
        repository = FakeConnection(events, "repository", FakeResult(one={"inserted": False}))
        source = FakeConnection(events, "source", FakeResult(one={"acknowledged": True}))

        result = snapshotter.transfer_batch(
            source, repository, source_alias="test-source", batch=batch()
        )

        self.assertEqual(result, (False, True))

    def test_batch_shape_mismatch_fails_before_ingest(self) -> None:
        with self.assertRaisesRegex(ValueError, "payload shape"):
            snapshotter.Batch.from_record(
                {
                    "batch_id": 8,
                    "captured_at": datetime.now(timezone.utc),
                    "row_count": 2,
                    "rows": [{"queryid": 1}],
                }
            )

    def test_retention_purge_is_scoped_to_configured_source(self) -> None:
        events: list[str] = []
        repository = FakeConnection(events, "repository", FakeResult(one={"deleted": 3}))

        deleted = snapshotter.purge_history(
            repository,
            source_alias="test-source",
            retention_days=30,
        )

        self.assertEqual(deleted, 3)
        query, params = repository.queries[0]
        self.assertIn("purge_join_source_history", query)
        self.assertNotIn("purge_join_history(", query)
        self.assertEqual(params, ("test-source", "30 days"))

    def test_error_summary_never_contains_exception_message(self) -> None:
        error = RuntimeError("postgresql://user:secret@source/powa payload contents")

        summary = snapshotter._error_summary(error)

        self.assertEqual(summary, "RuntimeError")
        self.assertNotIn("secret", summary)
        self.assertNotIn("payload", summary)

    def test_idle_cycle_checks_both_databases_before_marking_success(self) -> None:
        events: list[str] = []
        configured = settings()
        source = FakeConnection(events, "source", FakeResult(all_rows=[]))
        repository = FakeConnection(
            events, "repository", FakeResult(one={"ready": 1})
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            processed = snapshotter.run_cycle(
                configured,
                connector=connector,
                health_marker_path=marker_path,
                monotonic_ns=lambda: 123_456_789,
            )

            self.assertEqual(processed, 0)
            self.assertEqual(marker_path.read_text(encoding="ascii"), "123456789\n")
        self.assertLess(events.index("source:execute"), events.index("repository:execute"))
        self.assertLess(events.index("repository:close"), events.index("source:close"))

    def test_failed_repository_cycle_does_not_refresh_marker(self) -> None:
        events: list[str] = []
        configured = settings()
        source = FakeConnection(events, "source", FakeResult(all_rows=[]))
        repository = FakeConnection(events, "repository", RuntimeError("unavailable"))

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            snapshotter._write_health_marker(marker_path, completed_at_ns=41)

            with self.assertRaises(RuntimeError):
                snapshotter.run_cycle(
                    configured,
                    connector=connector,
                    health_marker_path=marker_path,
                    monotonic_ns=lambda: 99,
                )

            self.assertEqual(marker_path.read_text(encoding="ascii"), "41\n")

    def test_rejected_source_acknowledgement_does_not_mark_success(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(
                    all_rows=[
                        {
                            "batch_id": 7,
                            "captured_at": datetime(2026, 7, 25, tzinfo=timezone.utc),
                            "row_count": 1,
                            "rows": [{"queryid": -42, "isJoin": True}],
                        }
                    ]
                ),
                FakeResult(one={"acknowledged": False}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                FakeResult(one={"inserted": True}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            with self.assertRaisesRegex(RuntimeError, "acknowledgement"):
                snapshotter.run_cycle(
                    configured,
                    connector=connector,
                    health_marker_path=marker_path,
                    monotonic_ns=lambda: 99,
                )

            self.assertFalse(marker_path.exists())

    def test_health_marker_rejects_missing_stale_future_and_malformed_state(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            now_ns = 100_000_000_000

            self.assertFalse(
                snapshotter.health_marker_is_fresh(
                    marker_path, max_age_seconds=60, now_ns=now_ns
                )
            )

            snapshotter._write_health_marker(
                marker_path, completed_at_ns=now_ns - 59_000_000_000
            )
            self.assertTrue(
                snapshotter.health_marker_is_fresh(
                    marker_path, max_age_seconds=60, now_ns=now_ns
                )
            )
            self.assertFalse(
                snapshotter.health_marker_is_fresh(
                    marker_path,
                    max_age_seconds=60,
                    now_ns=now_ns + 2_000_000_000,
                )
            )

            snapshotter._write_health_marker(
                marker_path, completed_at_ns=now_ns + 1
            )
            self.assertFalse(
                snapshotter.health_marker_is_fresh(
                    marker_path, max_age_seconds=60, now_ns=now_ns
                )
            )

            marker_path.write_text("not-a-timestamp\n", encoding="ascii")
            self.assertFalse(
                snapshotter.health_marker_is_fresh(
                    marker_path, max_age_seconds=60, now_ns=now_ns
                )
            )

    def test_healthcheck_uses_configured_freshness_window(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            snapshotter._write_health_marker(marker_path, completed_at_ns=1_000_000_000)

            with mock.patch.dict(
                os.environ, {"JOIN_HEALTH_MAX_AGE_SECONDS": "10"}, clear=False
            ):
                self.assertEqual(
                    snapshotter.healthcheck(marker_path, now_ns=10_000_000_000), 0
                )
                self.assertEqual(
                    snapshotter.healthcheck(marker_path, now_ns=12_000_000_000), 1
                )


if __name__ == "__main__":
    unittest.main()
