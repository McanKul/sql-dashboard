from __future__ import annotations

import json
import logging
import math
import os
import random
import re
import signal
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol

import psycopg
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


LOGGER = logging.getLogger("advisor-join-snapshotter")
STOP_EVENT = threading.Event()
SAFE_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
HEALTH_MARKER_PATH = Path("/tmp/join-snapshotter-health")
DEFAULT_HEALTH_MAX_AGE_SECONDS = 60.0


class QueryResult(Protocol):
    def fetchone(self) -> Mapping[str, Any] | None: ...

    def fetchall(self) -> list[Mapping[str, Any]]: ...


class Transaction(Protocol):
    def __enter__(self) -> Any: ...

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> bool | None: ...


class DatabaseConnection(Protocol):
    def transaction(self) -> Transaction: ...

    def execute(self, query: str, params: tuple[Any, ...] = ()) -> QueryResult: ...


@dataclass(frozen=True)
class Settings:
    source_alias: str
    source_database_url: str
    repository_database_url: str
    poll_interval_seconds: float
    max_backoff_seconds: float
    batch_limit: int
    connect_timeout_seconds: int
    statement_timeout_ms: int
    retention_days: int
    purge_interval_seconds: float

    @classmethod
    def from_environment(cls) -> Settings:
        alias = _required_setting("JOIN_SOURCE_ALIAS")
        if not SAFE_ALIAS.fullmatch(alias):
            raise ValueError("JOIN_SOURCE_ALIAS has an invalid format")

        poll_interval = _float_setting("JOIN_POLL_INTERVAL_SECONDS", 2.0, minimum=0.25)
        max_backoff = _float_setting("JOIN_MAX_BACKOFF_SECONDS", 60.0, minimum=poll_interval)
        return cls(
            source_alias=alias,
            source_database_url=_database_conninfo(
                "JOIN_SOURCE_DATABASE",
                default_host="source-db",
                default_port=5432,
                default_name="powa",
                default_user="advisor_join_reader",
            ),
            repository_database_url=_database_conninfo(
                "JOIN_REPOSITORY_DATABASE",
                default_host="repository-db",
                default_port=5433,
                default_name="powa_repository",
                default_user="advisor_join_ingest",
            ),
            poll_interval_seconds=poll_interval,
            max_backoff_seconds=max_backoff,
            batch_limit=_int_setting("JOIN_BATCH_LIMIT", 20, minimum=1, maximum=100),
            connect_timeout_seconds=_int_setting(
                "JOIN_CONNECT_TIMEOUT_SECONDS", 5, minimum=1, maximum=30
            ),
            statement_timeout_ms=_int_setting(
                "JOIN_STATEMENT_TIMEOUT_MS", 30_000, minimum=1_000, maximum=120_000
            ),
            retention_days=_int_setting("JOIN_RETENTION_DAYS", 30, minimum=1, maximum=365),
            purge_interval_seconds=_float_setting(
                "JOIN_PURGE_INTERVAL_SECONDS", 3_600.0, minimum=60.0
            ),
        )


@dataclass(frozen=True)
class Batch:
    batch_id: int
    captured_at: datetime
    rows: list[dict[str, Any]]

    @classmethod
    def from_record(cls, record: Mapping[str, Any]) -> Batch:
        batch_id = int(record["batch_id"])
        captured_at = record["captured_at"]
        row_count = int(record["row_count"])
        rows = record["rows"]
        if isinstance(rows, str):
            rows = json.loads(rows)
        if batch_id < 1 or not isinstance(captured_at, datetime):
            raise ValueError("invalid JOIN outbox batch metadata")
        if not isinstance(rows, list) or len(rows) != row_count or row_count > 50_000:
            raise ValueError("invalid JOIN outbox batch payload shape")
        if not all(isinstance(row, dict) for row in rows):
            raise ValueError("invalid JOIN outbox row shape")
        return cls(batch_id=batch_id, captured_at=captured_at, rows=rows)


def _required_setting(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"{name} is required")
    return value


def _secret_setting(name: str) -> str:
    direct = os.getenv(name, "").strip()
    file_name = os.getenv(f"{name}_FILE", "").strip()
    if direct and file_name:
        raise ValueError(f"set only one of {name} and {name}_FILE")
    if file_name:
        lines = Path(file_name).read_text(encoding="utf-8").splitlines()
        value = lines[0].strip() if lines else ""
    else:
        value = direct
    if not value:
        raise ValueError(f"{name} or {name}_FILE is required")
    return value


def _password_setting(name: str) -> str:
    direct = os.getenv(name)
    file_name = os.getenv(f"{name}_FILE", "").strip()
    if direct not in (None, "") and file_name:
        raise ValueError(f"set only one of {name} and {name}_FILE")
    if file_name:
        lines = Path(file_name).read_text(encoding="utf-8").splitlines()
        value = lines[0] if lines else ""
    else:
        value = direct or ""
    if not value:
        raise ValueError(f"{name} or {name}_FILE is required")
    return value


def _database_conninfo(
    prefix: str,
    *,
    default_host: str,
    default_port: int,
    default_name: str,
    default_user: str,
) -> str:
    """Resolve a legacy URL override or safely build libpq keyword conninfo."""

    url_name = f"{prefix}_URL"
    if os.getenv(url_name, "").strip() or os.getenv(f"{url_name}_FILE", "").strip():
        try:
            return make_conninfo(_secret_setting(url_name))
        except Exception:
            raise ValueError(f"{url_name} is invalid") from None

    try:
        return make_conninfo(
            host=os.getenv(f"{prefix}_HOST", default_host).strip(),
            port=_int_setting(
                f"{prefix}_PORT", default_port, minimum=1, maximum=65_535
            ),
            dbname=os.getenv(f"{prefix}_NAME", default_name).strip(),
            user=os.getenv(f"{prefix}_USER", default_user).strip(),
            password=_password_setting(f"{prefix}_PASSWORD"),
            sslmode=os.getenv(f"{prefix}_SSLMODE", "disable").strip() or "disable",
        )
    except Exception as exc:
        if isinstance(exc, ValueError) and str(exc).endswith("is required"):
            raise
        raise ValueError(f"{prefix} connection settings are invalid") from None


def _int_setting(name: str, default: int, *, minimum: int, maximum: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if value < minimum or value > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _float_setting(
    name: str,
    default: float,
    *,
    minimum: float,
    maximum: float | None = None,
) -> float:
    raw = os.getenv(name, str(default))
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be numeric") from exc
    if not math.isfinite(value) or value < minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must be at most {maximum}")
    return value


def _log(event: str, *, level: int = logging.INFO, **fields: Any) -> None:
    # Only operational metadata is accepted by callers. DSNs and batch payloads
    # are deliberately never passed to this function.
    LOGGER.log(level, json.dumps({"event": event, **fields}, ensure_ascii=True, default=str))


def _error_summary(error: BaseException) -> str:
    sqlstate = getattr(error, "sqlstate", None)
    return f"{type(error).__name__}{f' sqlstate={sqlstate}' if sqlstate else ''}"


def _connect(database_url: str, settings: Settings) -> psycopg.Connection[dict[str, Any]]:
    connection = psycopg.connect(
        database_url,
        autocommit=True,
        row_factory=dict_row,
        connect_timeout=settings.connect_timeout_seconds,
        application_name="advisor-join-snapshotter",
    )
    connection.execute(
        "SELECT set_config('statement_timeout', %s, false), "
        "set_config('lock_timeout', '2s', false), "
        "set_config('idle_in_transaction_session_timeout', '5s', false)",
        (f"{settings.statement_timeout_ms}ms",),
    )
    return connection


def _write_health_marker(
    marker_path: Path = HEALTH_MARKER_PATH,
    *,
    completed_at_ns: int | None = None,
) -> None:
    completed_at_ns = time.monotonic_ns() if completed_at_ns is None else completed_at_ns
    if completed_at_ns < 0:
        raise ValueError("health marker timestamp cannot be negative")

    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="ascii",
            dir=marker_path.parent,
            prefix=f".{marker_path.name}.",
            delete=False,
        ) as marker:
            marker.write(f"{completed_at_ns}\n")
            temporary_path = Path(marker.name)
        os.replace(temporary_path, marker_path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _clear_health_marker(marker_path: Path = HEALTH_MARKER_PATH) -> None:
    marker_path.unlink(missing_ok=True)


def health_marker_is_fresh(
    marker_path: Path = HEALTH_MARKER_PATH,
    *,
    max_age_seconds: float,
    now_ns: int | None = None,
) -> bool:
    if not math.isfinite(max_age_seconds) or max_age_seconds <= 0:
        return False
    try:
        completed_at_ns = int(marker_path.read_text(encoding="ascii").strip())
    except (OSError, UnicodeError, ValueError):
        return False

    now_ns = time.monotonic_ns() if now_ns is None else now_ns
    age_ns = now_ns - completed_at_ns
    return 0 <= age_ns <= int(max_age_seconds * 1_000_000_000)


def healthcheck(
    marker_path: Path = HEALTH_MARKER_PATH,
    *,
    now_ns: int | None = None,
) -> int:
    try:
        max_age_seconds = _float_setting(
            "JOIN_HEALTH_MAX_AGE_SECONDS",
            DEFAULT_HEALTH_MAX_AGE_SECONDS,
            minimum=5.0,
            maximum=3_600.0,
        )
    except ValueError:
        return 1
    return (
        0
        if health_marker_is_fresh(
            marker_path,
            max_age_seconds=max_age_seconds,
            now_ns=now_ns,
        )
        else 1
    )


def fetch_batches(source: DatabaseConnection, batch_limit: int) -> list[Batch]:
    with source.transaction():
        records = source.execute(
            "SELECT * FROM advisor_join.fetch_batches(%s::integer)", (batch_limit,)
        ).fetchall()
    return [Batch.from_record(record) for record in records]


def probe_repository(repository: DatabaseConnection) -> None:
    with repository.transaction():
        result = repository.execute("SELECT 1 AS ready").fetchone()
        if result is None or result.get("ready") != 1:
            raise RuntimeError("repository health probe returned an invalid result")


def ingest_batch(
    repository: DatabaseConnection,
    *,
    source_alias: str,
    batch: Batch,
) -> bool:
    # Exiting this transaction context is the durability boundary. The source
    # acknowledgement is intentionally performed only after this returns.
    with repository.transaction():
        result = repository.execute(
            "SELECT advisor_ingest.ingest_join_batch(%s, %s, %s, %s::jsonb) AS inserted",
            (
                source_alias,
                batch.batch_id,
                batch.captured_at,
                Jsonb(batch.rows),
            ),
        ).fetchone()
        if result is None:
            raise RuntimeError("repository ingest returned no result")
        return bool(result["inserted"])


def acknowledge_batch(source: DatabaseConnection, batch_id: int) -> bool:
    with source.transaction():
        result = source.execute(
            "SELECT advisor_join.ack_batch(%s::bigint) AS acknowledged", (batch_id,)
        ).fetchone()
        if result is None:
            raise RuntimeError("source acknowledgement returned no result")
        return bool(result["acknowledged"])


def transfer_batch(
    source: DatabaseConnection,
    repository: DatabaseConnection,
    *,
    source_alias: str,
    batch: Batch,
) -> tuple[bool, bool]:
    inserted = ingest_batch(repository, source_alias=source_alias, batch=batch)
    acknowledged = acknowledge_batch(source, batch.batch_id)
    return inserted, acknowledged


def record_error(repository_url: str, settings: Settings, summary: str) -> None:
    try:
        with _connect(repository_url, settings) as repository:
            with repository.transaction():
                repository.execute(
                    "SELECT advisor_ingest.record_join_error(%s, %s)",
                    (settings.source_alias, summary[:500]),
                )
    except Exception as report_error:  # noqa: BLE001 - reporting must not mask the root failure
        _log(
            "error_status_unavailable",
            level=logging.WARNING,
            source=settings.source_alias,
            error=_error_summary(report_error),
        )


def purge_history(
    repository: DatabaseConnection,
    *,
    source_alias: str,
    retention_days: int,
) -> int:
    with repository.transaction():
        result = repository.execute(
            "SELECT advisor_ingest.purge_join_source_history(%s, %s::interval) AS deleted",
            (source_alias, f"{retention_days} days"),
        ).fetchone()
        if result is None:
            raise RuntimeError("repository purge returned no result")
        return int(result["deleted"] or 0)


def run_cycle(
    settings: Settings,
    *,
    connector: Callable[[str, Settings], psycopg.Connection[dict[str, Any]]] = _connect,
    health_marker_path: Path = HEALTH_MARKER_PATH,
    monotonic_ns: Callable[[], int] = time.monotonic_ns,
) -> int:
    processed = 0
    with connector(settings.source_database_url, settings) as source:
        batches = fetch_batches(source, settings.batch_limit)
        with connector(settings.repository_database_url, settings) as repository:
            # An idle source is still a complete cycle only after a repository
            # round-trip. This prevents repository outages from looking healthy
            # merely because there was no outbox work to ingest.
            probe_repository(repository)
            for batch in batches:
                inserted, acknowledged = transfer_batch(
                    source,
                    repository,
                    source_alias=settings.source_alias,
                    batch=batch,
                )
                if not acknowledged:
                    raise RuntimeError("source acknowledgement was not accepted")
                processed += 1
                _log(
                    "batch_transferred",
                    source=settings.source_alias,
                    batch_id=batch.batch_id,
                    row_count=len(batch.rows),
                    inserted=inserted,
                    acknowledged=acknowledged,
                )
    # Both connections have exited successfully, including every repository
    # commit and subsequent source acknowledgement.
    _write_health_marker(health_marker_path, completed_at_ns=monotonic_ns())
    return processed


def _backoff_seconds(settings: Settings, failures: int) -> float:
    exponential = settings.poll_interval_seconds * (2 ** min(failures - 1, 10))
    bounded = min(settings.max_backoff_seconds, exponential)
    return bounded + random.SystemRandom().uniform(0, bounded * 0.2)


def _handle_signal(signum: int, _frame: Any) -> None:
    _log("shutdown_requested", signal=signum)
    STOP_EVENT.set()


def run(settings: Settings) -> None:
    failures = 0
    next_purge_at = 0.0
    _clear_health_marker()
    _log("started", source=settings.source_alias)

    while not STOP_EVENT.is_set():
        try:
            processed = run_cycle(settings)
            failures = 0

            now = time.monotonic()
            if now >= next_purge_at:
                with _connect(settings.repository_database_url, settings) as repository:
                    deleted = purge_history(
                        repository,
                        source_alias=settings.source_alias,
                        retention_days=settings.retention_days,
                    )
                next_purge_at = now + settings.purge_interval_seconds
                _log("history_purged", source=settings.source_alias, deleted_batches=deleted)

            STOP_EVENT.wait(settings.poll_interval_seconds if processed == 0 else 0.0)
        except Exception as error:  # noqa: BLE001 - the daemon must retry transient DB failures
            failures += 1
            summary = _error_summary(error)
            delay = _backoff_seconds(settings, failures)
            _log(
                "cycle_failed",
                level=logging.ERROR,
                source=settings.source_alias,
                error=summary,
                retry_seconds=round(delay, 2),
            )
            record_error(settings.repository_database_url, settings, summary)
            STOP_EVENT.wait(delay)

    _log("stopped", source=settings.source_alias)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper(), format="%(message)s")
    if argv == ["--healthcheck"]:
        return healthcheck()
    if argv:
        _log("configuration_error", level=logging.CRITICAL, error="unexpected arguments")
        return 2

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    try:
        settings = Settings.from_environment()
    except (OSError, ValueError) as error:
        _log("configuration_error", level=logging.CRITICAL, error=_error_summary(error))
        return 2
    run(settings)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
