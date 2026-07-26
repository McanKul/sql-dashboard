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

from psycopg.conninfo import conninfo_to_dict, make_conninfo


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
        self.queries.append((_query, _params))
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def chunk() -> Any:
    return snapshotter.Chunk(
        batch_id=7,
        captured_at=datetime(2026, 7, 25, tzinfo=timezone.utc),
        total_row_count=1,
        row_offset=0,
        is_last=True,
        payload_bytes=512,
        rows=[{"queryid": -42, "isJoin": True}],
    )


def chunk_record(
    *,
    batch_id: int = 7,
    total_row_count: int = 1,
    row_offset: int = 0,
    rows: list[dict[str, Any]] | None = None,
    is_last: bool = True,
) -> dict[str, Any]:
    payload = [{"queryid": -42, "isJoin": True}] if rows is None else rows
    return {
        "batch_id": batch_id,
        "captured_at": datetime(2026, 7, 25, tzinfo=timezone.utc),
        "total_row_count": total_row_count,
        "row_offset": row_offset,
        "row_count": len(payload),
        "is_last": is_last,
        "payload_bytes": 512,
        "rows": payload,
    }


def header_record(
    *,
    batch_id: int = 7,
    total_row_count: int = 1,
) -> dict[str, Any]:
    return {
        "batch_id": batch_id,
        "captured_at": datetime(2026, 7, 25, tzinfo=timezone.utc),
        "total_row_count": total_row_count,
    }


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
    def test_settings_build_safe_conninfo_from_separate_fields(self) -> None:
        password = "strong@pass:/?%5432"
        environment = {
            "JOIN_SOURCE_ALIAS": "test-source",
            "JOIN_SOURCE_DATABASE_URL": "",
            "JOIN_SOURCE_DATABASE_URL_FILE": "",
            "JOIN_SOURCE_DATABASE_HOST": "source-db",
            "JOIN_SOURCE_DATABASE_PORT": "5432",
            "JOIN_SOURCE_DATABASE_NAME": "powa",
            "JOIN_SOURCE_DATABASE_USER": "advisor_join_reader",
            "JOIN_SOURCE_DATABASE_PASSWORD": password,
            "JOIN_SOURCE_DATABASE_SSLMODE": "disable",
            "JOIN_REPOSITORY_DATABASE_URL": "",
            "JOIN_REPOSITORY_DATABASE_URL_FILE": "",
            "JOIN_REPOSITORY_DATABASE_HOST": "repository-db",
            "JOIN_REPOSITORY_DATABASE_PORT": "5433",
            "JOIN_REPOSITORY_DATABASE_NAME": "powa_repository",
            "JOIN_REPOSITORY_DATABASE_USER": "advisor_join_ingest",
            "JOIN_REPOSITORY_DATABASE_PASSWORD": password,
            "JOIN_REPOSITORY_DATABASE_SSLMODE": "disable",
        }

        with mock.patch.dict(os.environ, environment, clear=True):
            configured = snapshotter.Settings.from_environment()

        source = conninfo_to_dict(configured.source_database_url)
        repository = conninfo_to_dict(configured.repository_database_url)
        self.assertEqual(source["password"], password)
        self.assertEqual(source["host"], "source-db")
        self.assertEqual(source["dbname"], "powa")
        self.assertEqual(repository["password"], password)
        self.assertEqual(repository["host"], "repository-db")
        self.assertEqual(repository["port"], "5433")

    def test_url_and_url_file_overrides_remain_supported(self) -> None:
        password = "legacy@pass:/?%5432"
        source_override = make_conninfo(
            host="legacy-source",
            port=6432,
            dbname="powa",
            user="legacy_reader",
            password=password,
        )
        repository_override = make_conninfo(
            host="legacy-repository",
            port=6433,
            dbname="powa_repository",
            user="legacy_ingest",
            password=password,
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            source_url_file = Path(temp_dir) / "source-url"
            source_url_file.write_text(f"{source_override}\n", encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {
                    "JOIN_SOURCE_ALIAS": "legacy-source",
                    "JOIN_SOURCE_DATABASE_URL_FILE": str(source_url_file),
                    "JOIN_REPOSITORY_DATABASE_URL": repository_override,
                },
                clear=True,
            ):
                configured = snapshotter.Settings.from_environment()

        source = conninfo_to_dict(configured.source_database_url)
        repository = conninfo_to_dict(configured.repository_database_url)
        self.assertEqual(source["host"], "legacy-source")
        self.assertEqual(source["password"], password)
        self.assertEqual(repository["host"], "legacy-repository")
        self.assertEqual(repository["password"], password)

    def test_url_and_url_file_conflict_still_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source_url_file = Path(temp_dir) / "source-url"
            source_url_file.write_text("host=file-source dbname=powa\n", encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {
                    "JOIN_SOURCE_ALIAS": "test-source",
                    "JOIN_SOURCE_DATABASE_URL": "host=direct-source dbname=powa",
                    "JOIN_SOURCE_DATABASE_URL_FILE": str(source_url_file),
                    "JOIN_REPOSITORY_DATABASE_URL": "host=repository-db dbname=powa_repository",
                },
                clear=True,
            ):
                with self.assertRaises(ValueError):
                    snapshotter.Settings.from_environment()

    def test_ack_happens_only_after_repository_finalize_commit(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(all_rows=[header_record()]),
                FakeResult(one=chunk_record()),
                FakeResult(one={"acknowledged": True}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                FakeResult(one={"inserted": True}),
                FakeResult(one={"finalized": True}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            processed = snapshotter.run_cycle(
                configured,
                connector=connector,
                health_marker_path=Path(temp_dir) / "health",
            )

        self.assertEqual(processed, 1)
        repository_commits = [
            index for index, event in enumerate(events) if event == "repository:commit"
        ]
        source_executes = [
            index for index, event in enumerate(events) if event == "source:execute"
        ]
        self.assertGreaterEqual(len(repository_commits), 3)
        self.assertGreaterEqual(len(source_executes), 3)
        self.assertLess(repository_commits[-1], source_executes[2])

    def test_repository_failure_leaves_source_batch_unacknowledged(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(all_rows=[header_record()]),
                FakeResult(one=chunk_record()),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [FakeResult(one={"ready": 1}), RuntimeError("do not expose me")],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            with self.assertRaises(RuntimeError):
                snapshotter.run_cycle(
                    configured,
                    connector=connector,
                    health_marker_path=Path(temp_dir) / "health",
                )

        self.assertEqual(events.count("source:execute"), 2)
        self.assertFalse(any("ack_batch" in query for query, _ in source.queries))
        self.assertIn("repository:rollback", events)

    def test_duplicate_repository_chunks_are_still_finalized_and_acknowledged(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(all_rows=[header_record()]),
                FakeResult(one=chunk_record()),
                FakeResult(one={"acknowledged": True}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                FakeResult(one={"inserted": False}),
                FakeResult(one={"finalized": False}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            processed = snapshotter.run_cycle(
                configured,
                connector=connector,
                health_marker_path=Path(temp_dir) / "health",
            )

        self.assertEqual(processed, 1)
        self.assertEqual(events.count("source:execute"), 3)

    def test_multi_chunk_batch_is_streamed_and_finalized_once(self) -> None:
        events: list[str] = []
        configured = settings()
        first = chunk_record(
            total_row_count=2,
            row_offset=0,
            rows=[{"queryid": -41, "isJoin": True}],
            is_last=False,
        )
        second = chunk_record(
            total_row_count=2,
            row_offset=1,
            rows=[{"queryid": -42, "isJoin": True}],
            is_last=True,
        )
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(all_rows=[header_record(total_row_count=2)]),
                FakeResult(one=first),
                FakeResult(one=second),
                FakeResult(one={"acknowledged": True}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                FakeResult(one={"inserted": True}),
                FakeResult(one={"inserted": True}),
                FakeResult(one={"finalized": True}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            processed = snapshotter.run_cycle(
                configured,
                connector=connector,
                health_marker_path=Path(temp_dir) / "health",
            )

        self.assertEqual(processed, 1)
        ingest_queries = [
            params
            for query, params in repository.queries
            if "ingest_join_chunk" in query
        ]
        self.assertEqual([params[4] for params in ingest_queries], [1, 2])
        self.assertEqual([params[5] for params in ingest_queries], [0, 1])
        self.assertEqual(
            sum("finalize_join_batch" in query for query, _params in repository.queries),
            1,
        )

    def test_failed_head_batch_does_not_block_later_batch(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(
                    all_rows=[header_record(batch_id=7), header_record(batch_id=8)]
                ),
                FakeResult(one=chunk_record(batch_id=7)),
                FakeResult(one=chunk_record(batch_id=8)),
                FakeResult(one={"acknowledged": True}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                RuntimeError("poison batch"),
                FakeResult(one={"inserted": True}),
                FakeResult(one={"finalized": True}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            with self.assertRaisesRegex(RuntimeError, "RuntimeError"):
                snapshotter.run_cycle(
                    configured,
                    connector=connector,
                    health_marker_path=marker_path,
                )
            self.assertFalse(marker_path.exists())

        ack_params = [
            params
            for query, params in source.queries
            if "ack_batch" in query
        ]
        self.assertEqual(ack_params, [(8,)])

    def test_batch_shape_mismatch_fails_before_ingest(self) -> None:
        with self.assertRaisesRegex(ValueError, "payload shape"):
            snapshotter.Chunk.from_record(
                {
                    "batch_id": 8,
                    "captured_at": datetime.now(timezone.utc),
                    "total_row_count": 2,
                    "row_offset": 0,
                    "row_count": 2,
                    "is_last": True,
                    "payload_bytes": 512,
                    "rows": [{"queryid": 1}],
                }
            )

    def test_chunk_limits_and_ranges_fail_closed(self) -> None:
        oversized = chunk_record(
            total_row_count=snapshotter.MAX_CHUNK_ROWS + 1,
            rows=[{}] * (snapshotter.MAX_CHUNK_ROWS + 1),
        )
        with self.assertRaisesRegex(ValueError, "payload shape"):
            snapshotter.Chunk.from_record(oversized)

        non_contiguous = chunk_record(
            total_row_count=3,
            row_offset=1,
            rows=[{}],
            is_last=False,
        )
        parsed = snapshotter.Chunk.from_record(non_contiguous)
        self.assertEqual(parsed.row_offset, 1)

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

        transported = snapshotter.SanitizedCycleError(
            "OperationalError sqlstate=54000"
        )
        self.assertEqual(
            snapshotter._error_summary(transported),
            "OperationalError sqlstate=54000",
        )

    def test_idle_cycle_checks_both_databases_before_marking_success(self) -> None:
        events: list[str] = []
        configured = settings()
        source = FakeConnection(events, "source", FakeResult(one=None))
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
        self.assertLess(events.index("repository:execute"), events.index("source:execute"))
        self.assertLess(events.index("repository:close"), events.index("source:close"))

    def test_failed_repository_cycle_does_not_refresh_marker(self) -> None:
        events: list[str] = []
        configured = settings()
        source = FakeConnection(events, "source", FakeResult(one=None))
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

    def test_already_acknowledged_source_batch_is_idempotent_success(self) -> None:
        events: list[str] = []
        configured = settings()
        source = SequencedFakeConnection(
            events,
            "source",
            [
                FakeResult(all_rows=[header_record()]),
                FakeResult(one=chunk_record()),
                FakeResult(one={"acknowledged": False}),
            ],
        )
        repository = SequencedFakeConnection(
            events,
            "repository",
            [
                FakeResult(one={"ready": 1}),
                FakeResult(one={"inserted": True}),
                FakeResult(one={"finalized": True}),
            ],
        )

        def connector(database_url: str, _settings: Any) -> FakeConnection:
            return source if database_url == configured.source_database_url else repository

        with tempfile.TemporaryDirectory() as temp_dir:
            marker_path = Path(temp_dir) / "health"
            processed = snapshotter.run_cycle(
                configured,
                connector=connector,
                health_marker_path=marker_path,
                monotonic_ns=lambda: 99,
            )

            self.assertEqual(processed, 1)
            self.assertEqual(marker_path.read_text(encoding="ascii"), "99\n")

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
