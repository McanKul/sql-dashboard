from __future__ import annotations

import asyncio
from collections import OrderedDict
from collections.abc import AsyncIterator, Callable, Mapping
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime
from decimal import Decimal
import logging
import re
from time import monotonic
from typing import Any
from uuid import NAMESPACE_URL, uuid5

from psycopg.errors import ObjectNotInPrerequisiteState

from app.config import (
    GLOBAL_TREND_SNAPSHOT_VIEWS,
    QUERY_METRICS_SNAPSHOT_VIEWS,
    WINDOW_BUCKETS,
    WINDOW_INTERVALS,
    get_settings,
)
from app.db import pool


logger = logging.getLogger(__name__)


SORT_COLUMNS = {
    "impact": "impact_score",
    "totalTime": "total_exec_time_ms",
    "meanTime": "mean_exec_time_ms",
    "calls": "calls",
    "regression": "regression_percent",
    "reads": "shared_blocks_read",
    "cpu": "cpu_total_time_ms",
    "waits": "wait_total_samples",
}

EXPORT_FETCH_SIZE = 500
QUERY_METRICS_CACHE_FETCH_SIZE = 1_000
OPTIMIZE_AFFECTED_QUERY_PREVIEW_SIZE = 20


class QueryMetricsSnapshotTooLarge(RuntimeError):
    """The complete metrics snapshot exceeded its configured memory guard."""


class QueryMetricsRefreshBackoff(RuntimeError):
    """A failed refresh is inside its bounded repository-protection backoff."""


class QueryMetricsSnapshotWarming(RuntimeError):
    """The persistent snapshot has not completed its first refresh yet."""


class GlobalTrendSnapshotWarming(QueryMetricsSnapshotWarming):
    """The persistent overview trend has not completed its first refresh yet."""


class GlobalTrendRefreshBackoff(RuntimeError):
    """A failed global-trend refresh is inside its bounded retry backoff."""


class GlobalTrendSnapshotTooLarge(RuntimeError):
    """The global trend exceeded the configured cache row guard."""


@dataclass(slots=True)
class _QueryMetricsCacheEntry:
    rows: list[dict[str, Any]]
    refreshed_at: float


@dataclass(slots=True)
class _GlobalTrendCacheEntry:
    rows: list[dict[str, Any]]
    refreshed_at: float


@dataclass(slots=True)
class _QueryMetricsRetryState:
    failures: int
    retry_not_before: float


TrendCacheKey = str | tuple[str, int, int | None]


def _sql_numeric_ge(value: Any, minimum: int | float) -> bool:
    """Apply SQL-like numeric >= filtering, where NULL/invalid is not true."""
    if value is None:
        return False
    try:
        numeric = Decimal(str(value))
        # PostgreSQL sorts numeric/float NaN above finite values, therefore a
        # SQL `metric >= finite_threshold` predicate includes it.
        if numeric.is_nan():
            return True
        return numeric >= Decimal(str(minimum))
    except (ArithmeticError, TypeError, ValueError):
        return False


class _IlikeMatcher:
    """PostgreSQL-LIKE wildcard matcher without regex backtracking.

    The NFA state set is encoded as one Python integer, so each input
    character performs a bounded number of bit operations.  This preserves
    ``%``, ``_`` and backslash escaping while preventing an unauthenticated
    search pattern from blocking the API event loop through catastrophic
    regular-expression backtracking.
    """

    def __init__(self, search: str) -> None:
        # `lower()` preserves one-codepoint wildcard width for characters such
        # as German sharp-s and tracks PostgreSQL ILIKE more closely than
        # Unicode `casefold()`, which can expand one character into several.
        pattern = f"%{search}%".lower()
        tokens: list[tuple[str, str | None]] = []
        index = 0
        while index < len(pattern):
            character = pattern[index]
            if character == "\\" and index + 1 < len(pattern):
                index += 1
                tokens.append(("literal", pattern[index]))
            elif character == "%":
                # Consecutive percent tokens are equivalent to one and would
                # otherwise require repeated epsilon-closure passes.
                if not tokens or tokens[-1][0] != "many":
                    tokens.append(("many", None))
            elif character == "_":
                tokens.append(("one", None))
            else:
                tokens.append(("literal", character))
            index += 1

        self._accept_mask = 1 << len(tokens)
        self._many_mask = 0
        self._one_mask = 0
        self._literal_masks: dict[str, int] = {}
        for token_index, (token_type, value) in enumerate(tokens):
            state_mask = 1 << token_index
            if token_type == "many":
                self._many_mask |= state_mask
            elif token_type == "one":
                self._one_mask |= state_mask
            else:
                assert value is not None
                self._literal_masks[value] = (
                    self._literal_masks.get(value, 0) | state_mask
                )

    def _epsilon_closure(self, states: int) -> int:
        # Consecutive percent tokens are collapsed during parsing, therefore
        # one transition is the complete epsilon closure.
        return states | ((states & self._many_mask) << 1)

    def fullmatch(self, value: str) -> bool:
        states = self._epsilon_closure(1)
        for character in value.lower():
            matching = self._one_mask | self._literal_masks.get(character, 0)
            states = (
                ((states & matching) << 1)
                | (states & self._many_mask)
            )
            states = self._epsilon_closure(states)
            if states == 0:
                return False
        return bool(self._epsilon_closure(states) & self._accept_mask)


def _ilike_matcher(search: str) -> _IlikeMatcher:
    return _IlikeMatcher(search)


def _query_id_sort_value(row: Mapping[str, Any]) -> int:
    return int(row.get("query_id") or 0)


def _metric_sort_value(row: Mapping[str, Any], column: str) -> tuple[int, Decimal]:
    value = Decimal(str(row[column]))
    # PostgreSQL numeric/float NaN sorts above ordinary numbers.  The tuple
    # avoids Decimal's InvalidOperation during comparisons while retaining
    # that ordering for DESC.
    if value.is_nan():
        return (1, Decimal(0))
    return (0, value)


def interval_for(window: str) -> str:
    try:
        return WINDOW_INTERVALS[window]
    except KeyError as exc:
        raise ValueError(f"Gecersiz zaman araligi: {window}") from exc


def _query_filters(
    *,
    search: str | None,
    priority: str | None,
    server_id: int | None,
    database_id: int | None,
    min_calls: int,
    min_duration_ms: float,
    regressions_only: bool,
) -> tuple[str, list[Any]]:
    """Build the shared, parameterized query-list/export filter clause."""
    conditions = ["calls >= %s", "total_exec_time_ms >= %s"]
    filters: list[Any] = [min_calls, min_duration_ms]

    if search:
        conditions.append("(sql_text ILIKE %s OR query_id::text ILIKE %s)")
        search_pattern = f"%{search}%"
        filters.extend([search_pattern, search_pattern])
    if priority:
        conditions.append("priority = %s")
        filters.append(priority.upper())
    if server_id is not None:
        conditions.append("server_id = %s")
        filters.append(server_id)
    if database_id is not None:
        conditions.append("database_id = %s")
        filters.append(database_id)
    if regressions_only:
        conditions.extend([
            "previous_period_available IS TRUE",
            "comparison_reliable IS TRUE",
            "regression_percent >= 20",
            "previous_calls >= 20",
            "calls >= 20",
        ])

    return " AND ".join(conditions), filters


def _as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, Decimal):
        return float(value)
    return float(value)


def _optional_float(value: Any) -> float | None:
    if value is None:
        return None
    return _as_float(value)


def _temporal_reliability(row: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize query window reliability without inventing missing history.

    The fallback branches keep the API compatible with a repository that has
    not yet applied the reliability migration.  Once the explicit SQL columns
    are present they are authoritative, including an explicit ``False``.
    """
    previous_period_value = row.get("previous_period_available")
    if previous_period_value is None:
        previous_period_available = (
            row.get("previous_calls") is not None
            and row.get("previous_mean_exec_time_ms") is not None
        )
    else:
        previous_period_available = bool(previous_period_value)

    reset_detected = bool(row.get("reset_detected"))
    comparison_value = row.get("comparison_reliable")
    comparison_reliable = (
        previous_period_available
        and not reset_detected
        and (True if comparison_value is None else bool(comparison_value))
    )
    warming_value = row.get("warming_up")

    coverage_percent = _optional_float(row.get("coverage_percent"))
    if coverage_percent is not None:
        coverage_percent = round(max(0.0, min(100.0, coverage_percent)), 2)

    return {
        "observedFrom": row.get("observed_from"),
        "observedTo": row.get("observed_to"),
        "coveragePercent": coverage_percent,
        "resetDetected": reset_detected,
        "comparisonReliable": comparison_reliable,
        "warmingUp": (
            not previous_period_available
            if warming_value is None
            else bool(warming_value)
        ),
        "previousPeriodAvailable": previous_period_available,
    }


P95_UNAVAILABLE_REASON = (
    "PoWA/pg_stat_statements kümülatif toplam ve çağrı sayısı tutar; "
    "tekil çalışma süresi dağılımı olmadığı için güvenilir p95 hesaplanamaz."
)


def score_breakdown(row: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    definitions = {
        "totalTime": ("total_time_score", 0.40),
        "physicalRead": ("physical_read_score", 0.20),
        "callFrequency": ("call_frequency_score", 0.15),
        "tempWrite": ("temp_write_score", 0.10),
        "regression": ("regression_score", 0.10),
        "wal": ("wal_score", 0.05),
    }
    details = row.get("score_details")
    result: dict[str, dict[str, Any]] = {}
    for key, (column, weight) in definitions.items():
        component = {
            "score": round(_as_float(row.get(column)), 2),
            "weight": weight,
            "contribution": round(_as_float(row.get(column)) * weight, 2),
        }
        detail = details.get(key) if isinstance(details, Mapping) else None
        if isinstance(detail, Mapping):
            component.update(
                {
                    "percentileScore": round(_as_float(detail.get("percentileScore")), 2),
                    "volumeFactor": round(_as_float(detail.get("volumeFactor")), 4),
                    "absoluteValue": round(_as_float(detail.get("absoluteValue")), 2),
                    "volumeValue": round(_as_float(detail.get("volumeValue")), 2),
                    "fullScoreAt": round(_as_float(detail.get("fullScoreAt")), 2),
                    "unit": str(detail.get("unit") or ""),
                }
            )
        result[key] = component
    return result


def findings_for(row: Mapping[str, Any]) -> list[str]:
    findings: list[str] = []
    if _as_float(row.get("db_load_percent")) >= 15:
        findings.append("Toplam veritabani suresinin onemli bir bolumunu kullaniyor.")
    if int(row.get("shared_blocks_read") or 0) > int(row.get("shared_blocks_hit") or 0) * 0.25:
        findings.append("Okunan shared blok miktari yuksek; sorgu plani incelenmeli.")
    reliability = _temporal_reliability(row)
    if (
        reliability["comparisonReliable"]
        and reliability["previousPeriodAvailable"]
        and _as_float(row.get("regression_percent")) >= 20
        and int(row.get("previous_calls") or 0) >= 20
        and int(row.get("calls") or 0) >= 20
    ):
        findings.append("Onceki es doneme gore ortalama calisma suresi geriledi.")
    if int(row.get("temp_blocks_written") or 0) > 0:
        findings.append("Gecici blok yazimi var; siralama/hash bellek kullanimi incelenmeli.")
    if _as_float(row.get("wal_bytes")) > 1_000_000:
        findings.append("WAL uretimi yuksek.")
    if row.get("kcache_data_available"):
        cpu_percent = _as_float(row.get("cpu_percent_of_exec_time"))
        if cpu_percent >= 70:
            findings.append("Calisma suresinin onemli bir bolumu gercek CPU tuketimi olarak olculdu.")
        elif _as_float(row.get("total_exec_time_ms")) >= 1000 and cpu_percent < 20:
            findings.append(
                "CPU payi dusuk; kalan sure bekleme veya I/O kaynakli olabilir ve wait telemetrisiyle ayrilmalidir."
            )
    wait_samples = int(row.get("wait_total_samples") or 0)
    wait_share = _as_float(row.get("dominant_wait_share_percent"))
    if row.get("wait_sampling_data_available") and wait_samples >= 10 and wait_share >= 40:
        category = str(row.get("dominant_wait_category") or "OTHER")
        event = str(row.get("dominant_wait_event") or "unknown")
        findings.append(
            f"Orneklenen beklemelerin %{wait_share:.0f} kadari {category}/{event}; baskin wait kaniti incelenmeli."
        )
    if not findings:
        findings.append("Belirgin bir risk esigi asilmadi; trend izlenmeli.")
    return findings


def serialize_query(row: Mapping[str, Any], *, sql_visible: bool) -> dict[str, Any]:
    raw_sql = str(row.get("sql_text") or "")
    kcache_available = bool(row.get("kcache_available"))
    kcache_data_available = kcache_available and bool(row.get("kcache_data_available"))
    if not kcache_available:
        kcache_reason = "pg_stat_kcache bu kaynakta etkin degil."
    elif not kcache_data_available:
        kcache_reason = "pg_stat_kcache etkin, ancak secili pencere ve sorgu icin iki snapshot arasinda CPU verisi yok."
    else:
        kcache_reason = (
            "CPU user/system ve filesystem I/O degerleri PoWA pg_stat_kcache gecmisinden gelir; "
            "paralel calismada toplam CPU suresi duvar saatini asabilir."
        )
    wait_available = bool(row.get("wait_sampling_available"))
    wait_data_available = wait_available and bool(row.get("wait_sampling_data_available"))
    wait_total_samples = int(row.get("wait_total_samples") or 0)
    wait_share = _as_float(row.get("dominant_wait_share_percent"))
    raw_wait_events = row.get("wait_events")
    wait_events = list(raw_wait_events) if isinstance(raw_wait_events, list) else []
    for event in wait_events:
        if isinstance(event, dict):
            event["sharePercent"] = round(
                100.0 * int(event.get("samples") or 0) / wait_total_samples,
                2,
            ) if wait_total_samples else 0.0
    if not wait_available:
        wait_reason = "pg_wait_sampling bu kaynakta etkin degil."
    elif not wait_data_available:
        wait_reason = "pg_wait_sampling etkin, ancak collector hatti henuz ilk snapshot'i tamamlamadi."
    elif wait_total_samples == 0:
        wait_reason = (
            "Collector hatti hazir; secili sorgu ve pencerede sampled wait yok. "
            "Bu durum tek basina CPU darboğazi kaniti degildir."
        )
    else:
        wait_reason = (
            "Oranlar yalniz sampled wait dagilimini gosterir; CPU suresiyle veya duvar saatiyle toplanmaz."
        )
    reliability = _temporal_reliability(row)
    previous_period_available = reliability["previousPeriodAvailable"]
    comparison_reliable = reliability["comparisonReliable"]
    previous_calls = row.get("previous_calls")
    previous_mean = row.get("previous_mean_exec_time_ms")
    regression_percent = row.get("regression_percent")
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "databaseId": row["database_id"],
        "databaseName": row.get("database_name") or f"db-{row['database_id']}",
        # PostgreSQL query_id is a signed bigint.  Returning it as text avoids
        # precision loss in JavaScript clients above Number.MAX_SAFE_INTEGER.
        "queryId": str(row["query_id"]),
        "userId": row.get("user_id"),
        "sql": raw_sql if sql_visible else _mask_sql(raw_sql),
        "sqlVisible": sql_visible,
        "calls": int(row.get("calls") or 0),
        "rows": int(row.get("rows") or 0),
        "rowsPerCall": round(_as_float(row.get("rows_per_call")), 2),
        "p95ExecTimeMs": None,
        "durationDistribution": {
            "available": False,
            "reason": P95_UNAVAILABLE_REASON,
        },
        "totalExecTimeMs": round(_as_float(row.get("total_exec_time_ms")), 2),
        "meanExecTimeMs": round(_as_float(row.get("mean_exec_time_ms")), 2),
        "dbLoadPercent": round(_as_float(row.get("db_load_percent")), 2),
        "sharedBlocksHit": int(row.get("shared_blocks_hit") or 0),
        "sharedBlocksRead": int(row.get("shared_blocks_read") or 0),
        "tempBlocksWritten": int(row.get("temp_blocks_written") or 0),
        "walBytes": round(_as_float(row.get("wal_bytes")), 2),
        "cpu": {
            "capability": {
                "available": kcache_available,
                "version": row.get("kcache_version"),
                "dataAvailable": kcache_data_available,
                "source": "PoWA pg_stat_kcache",
                "coverage": "EXECUTION_ONLY",
                "reason": kcache_reason,
            },
            "userTimeMs": round(_as_float(row.get("cpu_user_time_ms")), 2) if kcache_data_available else None,
            "systemTimeMs": round(_as_float(row.get("cpu_system_time_ms")), 2) if kcache_data_available else None,
            "totalTimeMs": round(_as_float(row.get("cpu_total_time_ms")), 2) if kcache_data_available else None,
            "percentOfExecTime": round(_as_float(row.get("cpu_percent_of_exec_time")), 2) if kcache_data_available else None,
            "filesystemReadsBytes": (
                int(row["filesystem_reads_bytes"])
                if kcache_data_available and row.get("filesystem_reads_bytes") is not None
                else None
            ),
            "filesystemWritesBytes": (
                int(row["filesystem_writes_bytes"])
                if kcache_data_available and row.get("filesystem_writes_bytes") is not None
                else None
            ),
            "scoreIncluded": False,
        },
        "waits": {
            "capability": {
                "available": wait_available,
                "version": row.get("wait_sampling_version"),
                "release": "1.1.11",
                "dataAvailable": wait_data_available,
                "source": "PoWA pg_wait_sampling",
                "coverage": "TOP_LEVEL_SAMPLED_WAITS",
                "reason": wait_reason,
            },
            "totalSamples": wait_total_samples if wait_data_available else None,
            "categories": {
                "io": int(row.get("wait_io_samples") or 0),
                "lock": int(row.get("wait_lock_samples") or 0),
                "lwlock": int(row.get("wait_lwlock_samples") or 0),
                "client": int(row.get("wait_client_samples") or 0),
                "ipc": int(row.get("wait_ipc_samples") or 0),
                "timeout": int(row.get("wait_timeout_samples") or 0),
                "activity": int(row.get("wait_activity_samples") or 0),
                "extension": int(row.get("wait_extension_samples") or 0),
                "other": int(row.get("wait_other_samples") or 0),
            } if wait_data_available else None,
            "dominant": {
                "category": row.get("dominant_wait_category"),
                "event": row.get("dominant_wait_event"),
                "sharePercent": round(wait_share, 2),
                "confidence": "MEDIUM" if wait_total_samples >= 50 and wait_share >= 50 else "LOW",
            } if wait_data_available and wait_total_samples >= 10 and row.get("dominant_wait_event") else None,
            "events": wait_events if wait_data_available else [],
            "scoreIncluded": False,
        },
        **reliability,
        "previousCalls": (
            int(previous_calls)
            if previous_period_available and previous_calls is not None
            else None
        ),
        "previousMeanExecTimeMs": (
            round(_as_float(previous_mean), 2)
            if previous_period_available and previous_mean is not None
            else None
        ),
        "regressionPercent": (
            round(_as_float(regression_percent), 2)
            if comparison_reliable and regression_percent is not None
            else None
        ),
        "impactScore": round(_as_float(row.get("impact_score")), 1),
        "priority": row.get("priority") or "LOW",
        "status": row.get("review_status") or "NEW",
        "note": row.get("note"),
        "updatedBy": row.get("updated_by"),
        "updatedAt": row.get("updated_at"),
        "findings": findings_for(row),
        "scoreBreakdown": score_breakdown(row),
    }


def _mask_sql(query: str) -> str:
    verb = (query.strip().split(maxsplit=1) or ["SQL"])[0].upper()
    return f"{verb} /* tam SQL metni icin analyst yetkisi gerekli */"


class PowaRepository:
    def __init__(
        self,
        *,
        query_list_cache_fresh_seconds: float | None = None,
        query_list_cache_stale_seconds: float | None = None,
        query_list_cache_max_entries: int | None = None,
        global_trend_cache_max_entries: int | None = None,
        query_list_cache_max_rows: int | None = None,
        query_list_cache_max_bytes: int | None = None,
        clock: Callable[[], float] = monotonic,
    ) -> None:
        settings = get_settings()
        self._query_list_cache_fresh_seconds = (
            settings.query_list_cache_fresh_seconds
            if query_list_cache_fresh_seconds is None
            else query_list_cache_fresh_seconds
        )
        self._query_list_cache_stale_seconds = (
            settings.query_list_cache_stale_seconds
            if query_list_cache_stale_seconds is None
            else query_list_cache_stale_seconds
        )
        self._query_list_cache_max_entries = (
            settings.query_list_cache_max_entries
            if query_list_cache_max_entries is None
            else query_list_cache_max_entries
        )
        self._global_trend_cache_max_entries = (
            settings.global_trend_cache_max_entries
            if global_trend_cache_max_entries is None
            else global_trend_cache_max_entries
        )
        self._query_list_cache_max_rows = (
            settings.query_list_cache_max_rows
            if query_list_cache_max_rows is None
            else query_list_cache_max_rows
        )
        self._query_list_cache_max_bytes = (
            settings.query_list_cache_max_bytes
            if query_list_cache_max_bytes is None
            else query_list_cache_max_bytes
        )
        if self._query_list_cache_fresh_seconds < 0:
            raise ValueError("query-list cache fresh suresi negatif olamaz")
        if (
            self._query_list_cache_stale_seconds
            < self._query_list_cache_fresh_seconds
        ):
            raise ValueError("query-list cache stale suresi fresh suresinden kisa olamaz")
        if not 1 <= self._query_list_cache_max_entries <= len(WINDOW_INTERVALS):
            raise ValueError("query-list cache entry siniri 1 ile desteklenen pencere sayisi arasinda olmali")
        if not 4 <= self._global_trend_cache_max_entries <= 1_024:
            raise ValueError("global trend cache entry siniri 4 ile 1024 arasinda olmali")
        if not 1 <= self._query_list_cache_max_rows <= 1_000_000:
            raise ValueError("query-list cache satir siniri 1 ile 1000000 arasinda olmali")
        if not 1024 * 1024 <= self._query_list_cache_max_bytes <= 1024 * 1024 * 1024:
            raise ValueError("query-list cache byte siniri 1 MiB ile 1 GiB arasinda olmali")

        self._query_metrics_cache: OrderedDict[str, _QueryMetricsCacheEntry] = (
            OrderedDict()
        )
        self._query_metrics_cache_generation = 0
        self._query_metrics_retry: dict[str, _QueryMetricsRetryState] = {}
        self._query_metrics_cache_lock = asyncio.Lock()
        # Global trends still require expensive live telemetry scans and share
        # this lock across windows. Query-metrics reloads read precomputed
        # materialized snapshots and intentionally do not queue behind it.
        self._repository_refresh_lock = asyncio.Lock()
        # Retain the old private name for compatibility with diagnostics.
        self._query_metrics_refresh_lock = self._repository_refresh_lock
        self._query_metrics_refresh_tasks: dict[
            tuple[int, str], asyncio.Task[list[dict[str, Any]]]
        ] = {}
        self._global_trend_cache: OrderedDict[TrendCacheKey, _GlobalTrendCacheEntry] = (
            OrderedDict()
        )
        self._global_trend_cache_generation = 0
        self._global_trend_retry: OrderedDict[
            TrendCacheKey, _QueryMetricsRetryState
        ] = OrderedDict()
        self._global_trend_cache_lock = asyncio.Lock()
        self._global_trend_refresh_tasks: dict[
            tuple[int, TrendCacheKey], asyncio.Task[list[dict[str, Any]]]
        ] = {}
        self._clock = clock

    async def _load_query_metrics_snapshot(self, window: str) -> list[dict[str, Any]]:
        interval_for(window)
        view_name = QUERY_METRICS_SNAPSHOT_VIEWS[window]
        async with pool.connection() as connection:
            # This is a bounded read of an already-computed materialized
            # snapshot. Live annotations are overlaid so an annotation mutation
            # does not have to trigger another full telemetry computation.
            async with connection.cursor() as control_cursor:
                await control_cursor.execute(
                    "SET LOCAL application_name = "
                    "'advisor-query-metrics-snapshot-read'"
                )

            async with connection.cursor(
                name="advisor_query_metrics_snapshot_read"
            ) as cursor:
                try:
                    await cursor.execute(
                        f"""
                    /* advisor-query-metrics-snapshot-read */
                    SELECT metrics.*,
                           COALESCE(annotation.status, 'NEW')
                               AS _live_review_status,
                           annotation.note AS _live_note,
                           annotation.updated_by AS _live_updated_by,
                           annotation.updated_at AS _live_updated_at,
                           pg_column_size(metrics)
                               AS _cache_row_bytes
                    FROM advisor.{view_name} AS metrics
                    LEFT JOIN advisor.query_annotations AS annotation
                      ON annotation.server_id = metrics.server_id
                     AND annotation.database_id = metrics.database_id
                     AND annotation.query_id = metrics.query_id
                    LIMIT %s
                    /* advisor-query-metrics-snapshot-read */
                    """,
                        (self._query_list_cache_max_rows + 1,),
                    )
                except ObjectNotInPrerequisiteState as error:
                    raise QueryMetricsSnapshotWarming(
                        f"query metrics snapshot {window} is warming"
                    ) from error
                rows: list[dict[str, Any]] = []
                payload_bytes = 0
                while True:
                    remaining = self._query_list_cache_max_rows + 1 - len(rows)
                    fetched = await cursor.fetchmany(
                        min(QUERY_METRICS_CACHE_FETCH_SIZE, remaining)
                    )
                    if not fetched:
                        return rows
                    for raw_row in fetched:
                        row = dict(raw_row)
                        row_bytes = row.pop("_cache_row_bytes", None)
                        if row_bytes is None:
                            raise RuntimeError(
                                "query metrics snapshot byte olcumu eksik"
                            )
                        payload_bytes += int(row_bytes)
                        if payload_bytes > self._query_list_cache_max_bytes:
                            raise QueryMetricsSnapshotTooLarge(
                                "query metrics snapshot configured byte limitini asti"
                            )
                        row["review_status"] = row.pop(
                            "_live_review_status", row.get("review_status") or "NEW"
                        )
                        row["note"] = row.pop("_live_note", row.get("note"))
                        row["updated_by"] = row.pop(
                            "_live_updated_by", row.get("updated_by")
                        )
                        row["updated_at"] = row.pop(
                            "_live_updated_at", row.get("updated_at")
                        )
                        rows.append(row)
                        if len(rows) > self._query_list_cache_max_rows:
                            raise QueryMetricsSnapshotTooLarge(
                                "query metrics snapshot configured row limitini asti"
                            )

    @staticmethod
    def _observe_query_metrics_refresh(
        task: asyncio.Task[list[dict[str, Any]]],
    ) -> None:
        """Consume background failures so asyncio never reports orphan errors."""
        if task.cancelled():
            return
        exception = task.exception()
        if exception is not None:
            # Do not include query/search values or connection details in this
            # best-effort background diagnostic.
            logger.warning(
                "query metrics cache refresh failed (%s)",
                type(exception).__name__,
            )

    def _start_query_metrics_refresh_locked(
        self,
        *,
        window: str,
        generation: int,
    ) -> asyncio.Task[list[dict[str, Any]]]:
        task_key = (generation, window)
        existing = self._query_metrics_refresh_tasks.get(task_key)
        if existing is not None:
            return existing

        task = asyncio.create_task(
            self._refresh_query_metrics_snapshot(
                window=window,
                generation=generation,
            ),
            name=f"query-metrics-cache-refresh-{window}",
        )
        self._query_metrics_refresh_tasks[task_key] = task
        task.add_done_callback(self._observe_query_metrics_refresh)
        return task

    async def _refresh_query_metrics_snapshot(
        self,
        *,
        window: str,
        generation: int,
    ) -> list[dict[str, Any]]:
        task_key = (generation, window)
        try:
            loaded_rows = await self._load_query_metrics_snapshot(window)
            if len(loaded_rows) > self._query_list_cache_max_rows:
                # Defense in depth for tests/custom repository subclasses that
                # override the bounded server-cursor loader.
                raise QueryMetricsSnapshotTooLarge(
                    "query metrics snapshot configured row limitini asti"
                )
            # Consumers treat raw rows as immutable and copy only the selected
            # page/detail. Retaining this single object avoids doubling a full
            # ERP-scale snapshot during every refresh.
            cached_rows = loaded_rows
            async with self._query_metrics_cache_lock:
                if generation == self._query_metrics_cache_generation:
                    self._query_metrics_retry.pop(window, None)
                    self._query_metrics_cache[window] = _QueryMetricsCacheEntry(
                        rows=cached_rows,
                        refreshed_at=self._clock(),
                    )
                    self._query_metrics_cache.move_to_end(window)
                    while (
                        len(self._query_metrics_cache)
                        > self._query_list_cache_max_entries
                    ):
                        self._query_metrics_cache.popitem(last=False)
            return loaded_rows
        except asyncio.CancelledError:
            raise
        except Exception:
            async with self._query_metrics_cache_lock:
                if generation == self._query_metrics_cache_generation:
                    previous = self._query_metrics_retry.get(window)
                    failures = 1 if previous is None else previous.failures + 1
                    # A persistent oversized snapshot or repository failure
                    # must not turn high request rate into repeated full scans.
                    delay_seconds = min(2 ** min(failures - 1, 6), 60)
                    self._query_metrics_retry[window] = _QueryMetricsRetryState(
                        failures=failures,
                        retry_not_before=self._clock() + delay_seconds,
                    )
            raise
        finally:
            async with self._query_metrics_cache_lock:
                current = self._query_metrics_refresh_tasks.get(task_key)
                if current is asyncio.current_task():
                    self._query_metrics_refresh_tasks.pop(task_key, None)

    async def _query_metrics_snapshot(self, window: str) -> list[dict[str, Any]]:
        """Return a role-neutral complete window snapshot with bounded SWR."""
        interval_for(window)
        async with self._query_metrics_cache_lock:
            generation = self._query_metrics_cache_generation
            entry = self._query_metrics_cache.get(window)
            retry = self._query_metrics_retry.get(window)
            now_monotonic = self._clock()
            if entry is not None:
                self._query_metrics_cache.move_to_end(window)
                age = max(0.0, now_monotonic - entry.refreshed_at)
                if age <= self._query_list_cache_fresh_seconds:
                    return entry.rows

                if age <= self._query_list_cache_stale_seconds:
                    if retry is None or now_monotonic >= retry.retry_not_before:
                        self._start_query_metrics_refresh_locked(
                            window=window,
                            generation=generation,
                        )
                    # Rows are never exposed directly: query_rows filters them
                    # read-only and deep-copies only the selected page.
                    return entry.rows

            if retry is not None and now_monotonic < retry.retry_not_before:
                raise QueryMetricsRefreshBackoff(
                    "query metrics refresh gecici backoff araliginda"
                )
            refresh = self._start_query_metrics_refresh_locked(
                window=window,
                generation=generation,
            )

        # Cold or too-old snapshots wait for the shared refresh. Shielding it
        # prevents a disconnected HTTP client from cancelling everybody's
        # single-flight database query.
        return await asyncio.shield(refresh)

    @staticmethod
    def _trend_cache_key(
        window: str,
        *,
        server_id: int | None,
        database_id: int | None,
    ) -> TrendCacheKey:
        if server_id is None:
            return window
        return (window, server_id, database_id)

    async def _load_global_trend_snapshot(
        self,
        window: str,
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        interval_for(window)
        view_name = GLOBAL_TREND_SNAPSHOT_VIEWS[window]
        async with pool.connection() as connection:
            async with connection.cursor() as control_cursor:
                await control_cursor.execute(
                    "SET LOCAL application_name = "
                    "'advisor-global-trend-snapshot-read'",
                    [],
                )
            async with connection.cursor() as cursor:
                try:
                    await cursor.execute(
                        f"""
                    /* advisor-global-trend-snapshot-read */
                    SELECT timestamp,
                           total_exec_time_ms,
                           calls
                    FROM advisor.{view_name}
                    WHERE server_id IS NOT DISTINCT FROM %s
                      AND database_id IS NOT DISTINCT FROM %s
                    ORDER BY timestamp
                    LIMIT %s
                    /* advisor-global-trend-snapshot-read */
                    """,
                        (
                            server_id,
                            database_id,
                            self._query_list_cache_max_rows + 1,
                        ),
                    )
                except ObjectNotInPrerequisiteState as error:
                    raise GlobalTrendSnapshotWarming(
                        f"global trend snapshot {window} is warming"
                    ) from error
                rows = [dict(row) for row in await cursor.fetchall()]
        if len(rows) > self._query_list_cache_max_rows:
            raise GlobalTrendSnapshotTooLarge(
                "global trend snapshot configured row limitini asti"
            )
        return rows

    @staticmethod
    def _observe_global_trend_refresh(
        task: asyncio.Task[list[dict[str, Any]]],
    ) -> None:
        """Consume background failures so asyncio never reports orphan errors."""
        if task.cancelled():
            return
        exception = task.exception()
        if exception is not None:
            logger.warning(
                "global trend cache refresh failed (%s)",
                type(exception).__name__,
            )

    def _start_global_trend_refresh_locked(
        self,
        *,
        window: str,
        generation: int,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> asyncio.Task[list[dict[str, Any]]]:
        cache_key = self._trend_cache_key(
            window, server_id=server_id, database_id=database_id
        )
        task_key = (generation, cache_key)
        existing = self._global_trend_refresh_tasks.get(task_key)
        if existing is not None:
            return existing

        task = asyncio.create_task(
            self._refresh_global_trend_snapshot(
                window=window,
                generation=generation,
                server_id=server_id,
                database_id=database_id,
            ),
            name=(
                f"global-trend-cache-refresh-{window}-"
                f"{server_id if server_id is not None else 'all'}-"
                f"{database_id if database_id is not None else 'all'}"
            ),
        )
        self._global_trend_refresh_tasks[task_key] = task
        task.add_done_callback(self._observe_global_trend_refresh)
        return task

    async def _refresh_global_trend_snapshot(
        self,
        *,
        window: str,
        generation: int,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        cache_key = self._trend_cache_key(
            window, server_id=server_id, database_id=database_id
        )
        task_key = (generation, cache_key)
        try:
            if server_id is None:
                loaded_rows = await self._load_global_trend_snapshot(window)
            else:
                loaded_rows = await self._load_global_trend_snapshot(
                    window,
                    server_id=server_id,
                    database_id=database_id,
                )
            if len(loaded_rows) > self._query_list_cache_max_rows:
                # Defense in depth for tests/custom subclasses that override
                # the bounded loader.
                raise GlobalTrendSnapshotTooLarge(
                    "global trend snapshot configured row limitini asti"
                )
            # Trend results are small. Copy on both sides of the cache boundary
            # so neither custom loaders nor response serializers can mutate a
            # shared snapshot.
            cached_rows = deepcopy(loaded_rows)
            async with self._global_trend_cache_lock:
                if generation == self._global_trend_cache_generation:
                    self._global_trend_retry.pop(cache_key, None)
                    self._global_trend_cache[cache_key] = _GlobalTrendCacheEntry(
                        rows=cached_rows,
                        refreshed_at=self._clock(),
                    )
                    self._global_trend_cache.move_to_end(cache_key)
                    while (
                        len(self._global_trend_cache)
                        > self._global_trend_cache_max_entries
                    ):
                        self._global_trend_cache.popitem(last=False)
            return cached_rows
        except asyncio.CancelledError:
            raise
        except Exception:
            async with self._global_trend_cache_lock:
                if generation == self._global_trend_cache_generation:
                    previous = self._global_trend_retry.get(cache_key)
                    failures = 1 if previous is None else previous.failures + 1
                    delay_seconds = min(2 ** min(failures - 1, 6), 60)
                    self._global_trend_retry[cache_key] = _QueryMetricsRetryState(
                        failures=failures,
                        retry_not_before=self._clock() + delay_seconds,
                    )
                    self._global_trend_retry.move_to_end(cache_key)
                    while (
                        len(self._global_trend_retry)
                        > self._global_trend_cache_max_entries
                    ):
                        self._global_trend_retry.popitem(last=False)
            raise
        finally:
            async with self._global_trend_cache_lock:
                current = self._global_trend_refresh_tasks.get(task_key)
                if current is asyncio.current_task():
                    self._global_trend_refresh_tasks.pop(task_key, None)

    async def _global_trend_snapshot(
        self,
        window: str,
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        """Return an immutable global or database trend with bounded SWR."""
        interval_for(window)
        cache_key = self._trend_cache_key(
            window, server_id=server_id, database_id=database_id
        )
        async with self._global_trend_cache_lock:
            generation = self._global_trend_cache_generation
            entry = self._global_trend_cache.get(cache_key)
            retry = self._global_trend_retry.get(cache_key)
            if retry is not None:
                self._global_trend_retry.move_to_end(cache_key)
            now_monotonic = self._clock()
            if entry is not None:
                self._global_trend_cache.move_to_end(cache_key)
                age = max(0.0, now_monotonic - entry.refreshed_at)
                if age <= self._query_list_cache_fresh_seconds:
                    return deepcopy(entry.rows)

                if age <= self._query_list_cache_stale_seconds:
                    if retry is None or now_monotonic >= retry.retry_not_before:
                        self._start_global_trend_refresh_locked(
                            window=window,
                            generation=generation,
                            server_id=server_id,
                            database_id=database_id,
                        )
                    return deepcopy(entry.rows)

            if retry is not None and now_monotonic < retry.retry_not_before:
                raise GlobalTrendRefreshBackoff(
                    "global trend refresh gecici backoff araliginda"
                )
            refresh = self._start_global_trend_refresh_locked(
                window=window,
                generation=generation,
                server_id=server_id,
                database_id=database_id,
            )

        # Cold or too-old misses wait for the per-window single-flight task.
        # Shielding prevents one disconnected request from cancelling it for
        # every concurrent overview request.
        return deepcopy(await asyncio.shield(refresh))

    @staticmethod
    def _filter_and_page_query_rows(
        rows: list[dict[str, Any]],
        *,
        page: int,
        page_size: int,
        search: str | None,
        priority: str | None,
        server_id: int | None,
        database_id: int | None,
        min_calls: int,
        min_duration_ms: float,
        sort_by: str,
        regressions_only: bool,
    ) -> tuple[list[dict[str, Any]], int]:
        search_matcher = _ilike_matcher(search) if search else None
        normalized_priority = priority.upper() if priority else None

        filtered: list[dict[str, Any]] = []
        for row in rows:
            if not _sql_numeric_ge(row.get("calls"), min_calls):
                continue
            if not _sql_numeric_ge(row.get("total_exec_time_ms"), min_duration_ms):
                continue
            if search_matcher is not None:
                sql_text = row.get("sql_text")
                query_id = row.get("query_id")
                sql_matches = sql_text is not None and search_matcher.fullmatch(
                    str(sql_text)
                )
                query_id_matches = query_id is not None and search_matcher.fullmatch(
                    str(query_id)
                )
                if not sql_matches and not query_id_matches:
                    continue
            if normalized_priority is not None and row.get("priority") != normalized_priority:
                continue
            if server_id is not None and row.get("server_id") != server_id:
                continue
            if database_id is not None and row.get("database_id") != database_id:
                continue
            if regressions_only and not (
                row.get("previous_period_available") is True
                and row.get("comparison_reliable") is True
                and _sql_numeric_ge(row.get("regression_percent"), 20)
                and _sql_numeric_ge(row.get("previous_calls"), 20)
                and _sql_numeric_ge(row.get("calls"), 20)
            ):
                continue
            filtered.append(row)

        order_column = SORT_COLUMNS.get(sort_by, SORT_COLUMNS["impact"])
        non_null = [row for row in filtered if row.get(order_column) is not None]
        nulls = [row for row in filtered if row.get(order_column) is None]
        # Two stable sorts exactly model `metric DESC NULLS LAST, query_id ASC`.
        non_null.sort(key=_query_id_sort_value)
        non_null.sort(key=lambda row: _metric_sort_value(row, order_column), reverse=True)
        nulls.sort(key=_query_id_sort_value)
        ordered = non_null + nulls

        total = len(ordered)
        offset = (page - 1) * page_size
        # Only the returned page is copied, keeping CPU/memory bounded while
        # preventing serializers/callers from mutating shared cache objects.
        return deepcopy(ordered[offset : offset + page_size]), total

    async def invalidate_query_rows_cache(self) -> None:
        """Invalidate cached dashboard snapshots after a local mutation."""
        async with self._query_metrics_cache_lock:
            self._query_metrics_cache_generation += 1
            self._query_metrics_cache.clear()
            self._query_metrics_retry.clear()
        async with self._global_trend_cache_lock:
            self._global_trend_cache_generation += 1
            self._global_trend_cache.clear()
            self._global_trend_retry.clear()

    async def close_query_rows_cache(self) -> None:
        """Cancel every tracked dashboard refresh before pool shutdown."""
        async with self._query_metrics_cache_lock:
            self._query_metrics_cache_generation += 1
            self._query_metrics_cache.clear()
            self._query_metrics_retry.clear()
            query_tasks = list(self._query_metrics_refresh_tasks.values())
            self._query_metrics_refresh_tasks.clear()
        async with self._global_trend_cache_lock:
            self._global_trend_cache_generation += 1
            self._global_trend_cache.clear()
            self._global_trend_retry.clear()
            trend_tasks = list(self._global_trend_refresh_tasks.values())
            self._global_trend_refresh_tasks.clear()
        tasks = [*query_tasks, *trend_tasks]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def ping(self) -> dict[str, Any]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT current_database() AS database_name,
                           current_setting('server_version') AS postgres_version,
                           (SELECT extversion FROM pg_extension WHERE extname = 'powa') AS powa_version,
                           pg_database_size(current_database()) AS repository_size_bytes
                    """
                )
                return dict(await cursor.fetchone())

    async def release_info(self) -> dict[str, Any]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute("SELECT * FROM advisor.release_info()")
                return dict(await cursor.fetchone())

    async def resolve_scope(
        self, *, server_id: int, database_id: int | None = None
    ) -> dict[str, Any] | None:
        clauses = ["server.id = %s", "server.id > 0", "server.frequency > 0"]
        params: list[Any] = [server_id]
        if database_id is not None:
            clauses.append("database.oid = %s")
            params.append(database_id)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT server.id AS server_id, server.alias AS server_alias,
                           database.oid AS database_id, database.datname AS database_name
                    FROM "PoWA".powa_servers AS server
                    LEFT JOIN "PoWA".powa_databases AS database
                      ON database.srvid = server.id AND database.dropped IS NULL
                    WHERE {' AND '.join(clauses)}
                      AND database.datname NOT IN ('powa', 'template0', 'template1')
                    ORDER BY database.datname
                    LIMIT 1
                    """,
                    params,
                )
                row = await cursor.fetchone()
                return None if row is None else dict(row)

    async def collector_health(
        self, server_id: int | None = None
    ) -> list[dict[str, Any]]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT server_id, alias, hostname, port, frequency,
                           retention::text AS retention,
                           CASE WHEN last_snapshot_at = '-infinity'::timestamptz
                                THEN NULL ELSE last_snapshot_at END AS last_snapshot_at,
                           CASE WHEN last_snapshot_at = '-infinity'::timestamptz
                                THEN NULL ELSE lag_seconds END AS lag_seconds,
                           errors, status
                    FROM advisor.v_collector_health
                    WHERE (%s::integer IS NULL OR server_id = %s::integer)
                    ORDER BY server_id
                    """
                    , (server_id, server_id)
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def servers(self) -> list[dict[str, Any]]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT id, alias, hostname, port, dbname,
                           frequency, retention::text AS retention, version
                    FROM "PoWA".powa_servers
                    WHERE id > 0 AND frequency > 0
                    ORDER BY id
                    """
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def databases(self, server_id: int | None = None) -> list[dict[str, Any]]:
        query = """
            SELECT d.srvid AS server_id, d.oid AS database_id, d.datname AS name, d.dropped
            FROM "PoWA".powa_databases AS d
            WHERE d.dropped IS NULL
              AND d.datname NOT IN ('powa', 'template0', 'template1')
        """
        params: list[Any] = []
        if server_id is not None:
            query += " AND d.srvid = %s"
            params.append(server_id)
        query += " ORDER BY d.srvid, d.datname"
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(query, params)
                return [dict(row) for row in await cursor.fetchall()]

    async def query_rows(
        self,
        *,
        window: str,
        page: int = 1,
        page_size: int = 50,
        search: str | None = None,
        priority: str | None = None,
        server_id: int | None = None,
        database_id: int | None = None,
        min_calls: int = 0,
        min_duration_ms: float = 0,
        sort_by: str = "impact",
        regressions_only: bool = False,
    ) -> tuple[list[dict[str, Any]], int]:
        rows = await self._query_metrics_snapshot(window)
        # Filtering/sorting a 100k-row snapshot is CPU work. Keep it away from
        # the Uvicorn event loop so health and unrelated requests stay live.
        return await asyncio.to_thread(
            self._filter_and_page_query_rows,
            rows,
            page=page,
            page_size=page_size,
            search=search,
            priority=priority,
            server_id=server_id,
            database_id=database_id,
            min_calls=min_calls,
            min_duration_ms=min_duration_ms,
            sort_by=sort_by,
            regressions_only=regressions_only,
        )

    async def stream_query_rows(
        self,
        *,
        window: str,
        search: str | None = None,
        priority: str | None = None,
        server_id: int | None = None,
        database_id: int | None = None,
        min_calls: int = 0,
        min_duration_ms: float = 0,
        sort_by: str = "impact",
        batch_size: int = EXPORT_FETCH_SIZE,
    ) -> AsyncIterator[list[dict[str, Any]]]:
        """Yield every filtered query through a bounded server-side cursor."""
        if batch_size < 1:
            raise ValueError("batch_size en az 1 olmali")

        interval = interval_for(window)
        where_sql, filters = _query_filters(
            search=search,
            priority=priority,
            server_id=server_id,
            database_id=database_id,
            min_calls=min_calls,
            min_duration_ms=min_duration_ms,
            regressions_only=False,
        )
        order_column = SORT_COLUMNS.get(sort_by, SORT_COLUMNS["impact"])
        data_query = f"""
            SELECT metrics.*, servers.alias AS server_alias
            FROM advisor.query_metrics(%s::interval) AS metrics
            LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
            WHERE {where_sql}
            ORDER BY {order_column} DESC NULLS LAST, query_id
        """

        async with pool.connection() as connection:
            # A named cursor keeps result transfer and API memory bounded even
            # when the filtered export contains far more than one UI page.
            async with connection.cursor(name="advisor_query_csv_export") as cursor:
                await cursor.execute(data_query, [interval, *filters])
                while True:
                    fetched = await cursor.fetchmany(batch_size)
                    if not fetched:
                        break
                    yield [dict(row) for row in fetched]

    async def overview_summary(
        self,
        *,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> dict[str, Any]:
        """Aggregate every tracked query; pagination must never affect cards."""
        rows = await self._query_metrics_snapshot(window)
        return await asyncio.to_thread(
            self._overview_summary_from_rows,
            rows,
            server_id=server_id,
            database_id=database_id,
        )

    @staticmethod
    def _overview_summary_from_rows(
        rows: list[dict[str, Any]],
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> dict[str, Any]:
        scoped_rows = [
            row
            for row in rows
            if (server_id is None or row.get("server_id") == server_id)
            and (database_id is None or row.get("database_id") == database_id)
        ]
        return {
            "total_db_time_ms": float(
                sum(
                    (_as_float(row.get("total_exec_time_ms")) for row in scoped_rows),
                    start=0.0,
                )
            ),
            "tracked_queries": len(scoped_rows),
            "critical_queries": sum(
                1 for row in scoped_rows if row.get("priority") == "CRITICAL"
            ),
            "regressions": sum(
                1
                for row in scoped_rows
                if row.get("previous_period_available") is True
                and row.get("comparison_reliable") is True
                and _sql_numeric_ge(row.get("regression_percent"), 20)
                and _sql_numeric_ge(row.get("previous_calls"), 20)
                and _sql_numeric_ge(row.get("calls"), 20)
            ),
        }

    async def query_by_id(
        self,
        *,
        query_id: int,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> dict[str, Any] | None:
        rows = await self._query_metrics_snapshot(window)
        return await asyncio.to_thread(
            self._query_by_id_from_rows,
            rows,
            query_id=query_id,
            server_id=server_id,
            database_id=database_id,
        )

    @staticmethod
    def _query_by_id_from_rows(
        rows: list[dict[str, Any]],
        *,
        query_id: int,
        server_id: int | None,
        database_id: int | None,
    ) -> dict[str, Any] | None:
        candidates = [
            row
            for row in rows
            if row.get("query_id") == query_id
            and (server_id is None or row.get("server_id") == server_id)
            and (database_id is None or row.get("database_id") == database_id)
        ]
        if not candidates:
            return None

        # Preserve the prior SQL's `ORDER BY impact_score DESC` behavior:
        # DESC defaults to NULLS FIRST, and Python's stable max keeps snapshot
        # order for otherwise unspecified ties.
        selected = max(
            candidates,
            key=lambda row: (
                row.get("impact_score") is None,
                (
                    _metric_sort_value(row, "impact_score")
                    if row.get("impact_score") is not None
                    else (0, Decimal(0))
                ),
            ),
        )
        return deepcopy(selected)

    async def trend(
        self,
        *,
        window: str,
        query_id: int | None = None,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        if database_id is not None and server_id is None:
            raise ValueError(
                "Trend database_id kapsami server_id alanini gerektirir."
            )
        if query_id is not None and (server_id is None or database_id is None):
            raise ValueError("Query trend kapsami server_id ve database_id gerektirir.")
        if query_id is None:
            return await self._global_trend_snapshot(
                window,
                server_id=server_id,
                database_id=database_id,
            )
        interval = interval_for(window)
        bucket = WINDOW_BUCKETS[window]
        function_sql = (
            "advisor.query_trend("
            "now() - %s::interval, %s::interval, %s, %s, %s)"
        )
        params: list[Any] = [interval, bucket, server_id, database_id, query_id]
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT bucket_at AS timestamp,
                           total_exec_time_ms,
                           calls
                    FROM {function_sql}
                    """,
                    params,
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def index_rows(
        self,
        *,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        interval = interval_for(window)
        clauses = ["TRUE"]
        filters: list[Any] = []
        if server_id is not None:
            clauses.append("server_id = %s")
            filters.append(server_id)
        if database_id is not None:
            clauses.append("database_id = %s")
            filters.append(database_id)
        where_sql = " AND ".join(clauses)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT
                        count(*)::bigint AS indexes_observed,
                        count(*) FILTER (WHERE signal IN (
                            'NO_SCANS_OBSERVED', 'LOW_USAGE_OBSERVED'
                        ))::bigint AS candidate_signals,
                        COALESCE(sum(size_bytes), 0)::bigint AS total_size_bytes,
                        COALESCE(sum(size_bytes) FILTER (
                            WHERE signal = 'NO_SCANS_OBSERVED'
                        ), 0)::bigint AS no_scan_size_bytes
                    FROM advisor.index_metrics(%s::interval)
                    WHERE {where_sql}
                    """,
                    [interval, *filters],
                )
                summary = dict(await cursor.fetchone())
                await cursor.execute(
                    f"""
                    SELECT metrics.*, servers.alias AS server_alias
                    FROM advisor.index_metrics(%s::interval) AS metrics
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
                    WHERE {where_sql}
                    ORDER BY
                        CASE signal_level
                            WHEN 'WARNING' THEN 1 WHEN 'NOTICE' THEN 2 ELSE 3 END,
                        size_bytes DESC,
                        index_id
                    LIMIT 500
                    """,
                    [interval, *filters],
                )
                rows = [dict(row) for row in await cursor.fetchall()]
        return rows, summary

    async def io_telemetry(
        self,
        *,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
        interval = interval_for(window)
        database_clauses = ["TRUE"]
        database_filters: list[Any] = []
        if server_id is not None:
            database_clauses.append("metrics.server_id = %s")
            database_filters.append(server_id)
        if database_id is not None:
            database_clauses.append("metrics.database_id = %s")
            database_filters.append(database_id)

        server_clauses = ["TRUE"]
        server_filters: list[Any] = []
        if server_id is not None:
            server_clauses.append("metrics.server_id = %s")
            server_filters.append(server_id)
        if database_id is not None:
            server_clauses.append(
                "metrics.server_id IN ("
                "SELECT srvid FROM \"PoWA\".powa_databases "
                "WHERE oid = %s AND dropped IS NULL)"
            )
            server_filters.append(database_id)

        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT metrics.*, servers.alias AS server_alias
                    FROM advisor.database_io_metrics(%s::interval) AS metrics
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
                    WHERE {' AND '.join(database_clauses)}
                    ORDER BY metrics.server_id, metrics.database_name
                    """,
                    [interval, *database_filters],
                )
                databases = [dict(row) for row in await cursor.fetchall()]
                await cursor.execute(
                    f"""
                    SELECT metrics.*, servers.alias AS server_alias
                    FROM advisor.io_metrics(%s::interval) AS metrics
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
                    WHERE {' AND '.join(server_clauses)}
                    ORDER BY metrics.read_bytes + metrics.write_bytes DESC,
                             metrics.backend_type, metrics.object, metrics.context
                    """,
                    [interval, *server_filters],
                )
                contexts = [dict(row) for row in await cursor.fetchall()]
                await cursor.execute(
                    f"""
                    SELECT metrics.*, servers.alias AS server_alias
                    FROM advisor.operation_metrics(%s::interval) AS metrics
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
                    WHERE {' AND '.join(server_clauses)}
                    ORDER BY metrics.server_id
                    """,
                    [interval, *server_filters],
                )
                servers = [dict(row) for row in await cursor.fetchall()]
        return databases, contexts, servers

    async def table_health(
        self,
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        clauses = ["TRUE"]
        params: list[Any] = []
        if server_id is not None:
            clauses.append("health.server_id = %s")
            params.append(server_id)
        if database_id is not None:
            clauses.append("health.database_id = %s")
            params.append(database_id)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT health.*, servers.alias AS server_alias
                    FROM advisor.v_table_health AS health
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = health.server_id
                    WHERE {' AND '.join(clauses)}
                    ORDER BY
                        CASE signal_level
                            WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2
                            WHEN 'NOTICE' THEN 3 ELSE 4 END,
                        dead_tuples DESC
                    LIMIT 200
                    """,
                    params,
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def table_health_summary(
        self,
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> dict[str, Any]:
        clauses = ["TRUE"]
        params: list[Any] = []
        if server_id is not None:
            clauses.append("server_id = %s")
            params.append(server_id)
        if database_id is not None:
            clauses.append("database_id = %s")
            params.append(database_id)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT count(*)::bigint AS tables_observed,
                           count(*) FILTER (WHERE signal_level = 'CRITICAL')::bigint AS critical,
                           count(*) FILTER (WHERE signal_level = 'WARNING')::bigint AS warnings,
                           count(*) FILTER (WHERE signal_level = 'NOTICE')::bigint AS notices
                    FROM advisor.v_table_health
                    WHERE {' AND '.join(clauses)}
                    """,
                    params,
                )
                return dict(await cursor.fetchone())

    async def long_transactions(
        self,
        *,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        clauses = ["TRUE"]
        params: list[Any] = []
        if server_id is not None:
            clauses.append("server_id = %s")
            params.append(server_id)
        if database_id is not None:
            clauses.append("database_id = %s")
            params.append(database_id)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    f"""
                    SELECT * FROM advisor.v_long_transactions
                    WHERE {' AND '.join(clauses)}
                    ORDER BY age_seconds DESC
                    LIMIT 100
                    """,
                    params,
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def predicate_evidence(
        self,
        *,
        window: str,
        server_id: int,
        database_id: int,
        query_id: int,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.predicate_metrics(
                        %s::interval,
                        %s::integer,
                        %s::oid,
                        %s::bigint
                    )
                    """,
                    (interval, server_id, database_id, query_id),
                )
                rows = [dict(row) for row in await cursor.fetchall()]
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.predicate_capability(%s::integer)
                    """,
                    (server_id,),
                )
                capability = dict(await cursor.fetchone())
        return rows, capability

    async def join_evidence(
        self,
        *,
        window: str,
        server_id: int,
        database_id: int,
        query_id: int,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.join_predicate_metrics(
                        %s::interval,
                        %s::integer,
                        %s::oid,
                        %s::bigint
                    )
                    """,
                    (interval, server_id, database_id, query_id),
                )
                rows = [dict(row) for row in await cursor.fetchall()]
                await cursor.execute(
                    "SELECT * FROM advisor.join_snapshot_capability(%s::integer)",
                    (server_id,),
                )
                capability = dict(await cursor.fetchone())
        return rows, capability

    async def composite_candidates(
        self,
        *,
        window: str,
        server_id: int,
        database_id: int,
        query_id: int,
    ) -> list[dict[str, Any]]:
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.composite_index_candidates(
                        %s::interval,
                        %s::integer,
                        %s::oid,
                        %s::bigint
                    )
                    """,
                    (interval, server_id, database_id, query_id),
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def composite_candidate(
        self,
        *,
        candidate_id: str,
        server_id: int,
        database_id: int,
        query_id: int,
        window: str,
    ) -> dict[str, Any] | None:
        rows = await self.composite_candidates(
            window=window,
            server_id=server_id,
            database_id=database_id,
            query_id=query_id,
        )
        return next(
            (row for row in rows if str(row["candidate_id"]) == candidate_id),
            None,
        )

    async def capability_rows(
        self,
        *,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    WITH requested AS MATERIALIZED (
                        SELECT %s::interval AS metric_window,
                               %s::integer AS server_id,
                               %s::oid AS database_id,
                               now() AS observed_until
                    ), telemetry_data AS MATERIALIZED (
                        -- Capability discovery must stay independent from the
                        -- full advisor.query_metrics scoring scan.  The PoWA
                        -- statement catalogue is small, indexed by scope and
                        -- carries the last collector observation timestamp.
                        -- Historical readiness is catalogue evidence only;
                        -- CPU and wait readiness below come from their own
                        -- datasource tables and can therefore fail closed
                        -- independently.
                        SELECT statement.srvid AS server_id,
                               statement.dbid AS database_id,
                               true AS data_available
                        FROM requested
                        JOIN "PoWA".powa_statements AS statement
                          ON statement.last_present_ts
                                 >= requested.observed_until - requested.metric_window
                         AND statement.last_present_ts <= requested.observed_until
                         AND (requested.server_id IS NULL
                              OR statement.srvid = requested.server_id)
                         AND (requested.database_id IS NULL
                              OR statement.dbid = requested.database_id)
                        JOIN "PoWA".powa_databases AS tracked_database
                          ON tracked_database.srvid = statement.srvid
                         AND tracked_database.oid = statement.dbid
                         AND tracked_database.dropped IS NULL
                         AND tracked_database.datname
                                 NOT IN ('powa', 'template0', 'template1')
                        WHERE statement.query ~*
                            '^[[:space:]]*((/[*].*[*]/|--[^\r\n]*[\r\n]+)[[:space:]]*)*(SELECT|WITH|INSERT|UPDATE|DELETE|MERGE)([[:space:]]|$)'
                          AND EXISTS (
                              SELECT 1
                              FROM "PoWA".powa_snapshot_metas AS snapshot
                              WHERE snapshot.srvid = statement.srvid
                                AND snapshot.snapts
                                      >= requested.observed_until
                                         - requested.metric_window
                                AND snapshot.snapts
                                      <= requested.observed_until
                          )
                          AND NOT EXISTS (
                              SELECT 1
                              FROM "PoWA".powa_catalog_roles AS excluded_role
                              WHERE excluded_role.srvid = statement.srvid
                                AND excluded_role.oid = statement.userid
                                AND excluded_role.rolname IN (
                                    'powa_collector', 'advisor_evaluator'
                                )
                          )
                        GROUP BY statement.srvid, statement.dbid
                    ), kcache_data AS MATERIALIZED (
                        -- Coalesced ranges and current composite timestamps
                        -- are narrow PoWA headers; no metric arrays are
                        -- unnested and no query scoring function is invoked.
                        -- Exact database requests use short-circuit EXISTS;
                        -- fleet/server matrices scan each datasource once.
                        SELECT requested.server_id AS server_id,
                               requested.database_id AS database_id,
                               true AS data_available
                        FROM requested
                        WHERE requested.database_id IS NOT NULL
                          AND (
                              EXISTS (
                                  SELECT 1
                                  FROM "PoWA".powa_kcache_metrics_current
                                      AS current_sample
                                  WHERE current_sample.srvid = requested.server_id
                                    AND current_sample.dbid = requested.database_id
                                    AND current_sample.top
                                    AND current_sample.metrics IS NOT NULL
                                    AND (current_sample.metrics).ts
                                          >= requested.observed_until
                                             - requested.metric_window
                                    AND (current_sample.metrics).ts
                                          <= requested.observed_until
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM "PoWA".powa_kcache_metrics AS history
                                  WHERE history.srvid = requested.server_id
                                    AND history.dbid = requested.database_id
                                    AND history.top
                                    AND history.coalesce_range && tstzrange(
                                        requested.observed_until
                                            - requested.metric_window,
                                        requested.observed_until,
                                        '[]'
                                    )
                              )
                          )

                        UNION

                        SELECT DISTINCT history.srvid AS server_id,
                               history.dbid AS database_id,
                               true AS data_available
                        FROM requested
                        JOIN "PoWA".powa_kcache_metrics AS history
                          ON (requested.server_id IS NULL
                              OR history.srvid = requested.server_id)
                         AND (requested.database_id IS NULL
                              OR history.dbid = requested.database_id)
                         AND history.coalesce_range && tstzrange(
                             requested.observed_until
                                 - requested.metric_window,
                             requested.observed_until,
                             '[]'
                         )
                        WHERE requested.database_id IS NULL
                          AND history.top

                        UNION

                        SELECT DISTINCT current_sample.srvid,
                               current_sample.dbid,
                               true
                        FROM requested
                        JOIN "PoWA".powa_kcache_metrics_current
                            AS current_sample
                          ON (requested.server_id IS NULL
                              OR current_sample.srvid = requested.server_id)
                         AND (requested.database_id IS NULL
                              OR current_sample.dbid = requested.database_id)
                        WHERE current_sample.top
                          AND requested.database_id IS NULL
                          AND current_sample.metrics IS NOT NULL
                          AND (current_sample.metrics).ts
                                >= requested.observed_until
                                   - requested.metric_window
                          AND (current_sample.metrics).ts
                                <= requested.observed_until
                    ), wait_data AS MATERIALIZED (
                        SELECT requested.server_id AS server_id,
                               requested.database_id AS database_id,
                               true AS data_available
                        FROM requested
                        WHERE requested.database_id IS NOT NULL
                          AND (
                              EXISTS (
                                  SELECT 1
                                  FROM "PoWA".powa_wait_sampling_history_current
                                      AS current_sample
                                  WHERE current_sample.srvid = requested.server_id
                                    AND current_sample.dbid = requested.database_id
                                    AND (current_sample.record).ts
                                          >= requested.observed_until
                                             - requested.metric_window
                                    AND (current_sample.record).ts
                                          <= requested.observed_until
                              )
                              OR EXISTS (
                                  SELECT 1
                                  FROM "PoWA".powa_wait_sampling_history AS history
                                  WHERE history.srvid = requested.server_id
                                    AND history.dbid = requested.database_id
                                    AND history.coalesce_range && tstzrange(
                                        requested.observed_until
                                            - requested.metric_window,
                                        requested.observed_until,
                                        '[]'
                                    )
                              )
                          )

                        UNION

                        SELECT DISTINCT history.srvid AS server_id,
                               history.dbid AS database_id,
                               true AS data_available
                        FROM requested
                        JOIN "PoWA".powa_wait_sampling_history AS history
                          ON (requested.server_id IS NULL
                              OR history.srvid = requested.server_id)
                         AND (requested.database_id IS NULL
                              OR history.dbid = requested.database_id)
                         AND history.coalesce_range && tstzrange(
                             requested.observed_until
                                 - requested.metric_window,
                             requested.observed_until,
                             '[]'
                         )
                        WHERE requested.database_id IS NULL

                        UNION

                        SELECT DISTINCT current_sample.srvid,
                               current_sample.dbid,
                               true
                        FROM requested
                        JOIN "PoWA".powa_wait_sampling_history_current
                            AS current_sample
                          ON (requested.server_id IS NULL
                              OR current_sample.srvid = requested.server_id)
                         AND (requested.database_id IS NULL
                              OR current_sample.dbid = requested.database_id)
                        WHERE requested.database_id IS NULL
                          AND (current_sample.record).ts
                                >= requested.observed_until
                                   - requested.metric_window
                          AND (current_sample.record).ts
                                <= requested.observed_until
                    ), predicate_data AS MATERIALIZED (
                        SELECT DISTINCT metric.server_id, metric.database_id,
                               true AS data_available
                        FROM requested
                        CROSS JOIN LATERAL advisor.predicate_metrics(
                            requested.metric_window,
                            requested.server_id,
                            requested.database_id,
                            NULL::bigint
                        ) AS metric
                    ), join_data AS MATERIALIZED (
                        -- The ingest tables intentionally remain hidden from
                        -- advisor_api.  This SECURITY DEFINER adapter is the
                        -- narrow evidence surface and is evaluated once for
                        -- the requested fleet/scope, not once per database.
                        SELECT DISTINCT metric.server_id, metric.database_id,
                               true AS data_available
                        FROM requested
                        CROSS JOIN LATERAL advisor.join_predicate_metrics(
                            requested.metric_window,
                            requested.server_id,
                            requested.database_id,
                            NULL::bigint
                        ) AS metric
                    ), join_capabilities AS MATERIALIZED (
                        SELECT source.id AS server_id, capability.*
                        FROM requested
                        JOIN "PoWA".powa_servers AS source
                          ON source.id > 0 AND source.frequency > 0
                         AND (requested.server_id IS NULL OR source.id = requested.server_id)
                        CROSS JOIN LATERAL advisor.join_snapshot_capability(source.id)
                            AS capability
                    )
                    SELECT server.id AS server_id, server.alias AS server_alias,
                           database.oid AS database_id, database.datname AS database_name,
                           collector.status AS collector_status,
                           collector.last_snapshot_at,
                           COALESCE(telemetry.data_available, false)
                               AS historical_data_available,
                           max(config.version) FILTER (WHERE config.extname = 'pg_stat_kcache') AS kcache_version,
                           COALESCE(bool_or(config.enabled) FILTER (WHERE config.extname = 'pg_stat_kcache'), false) AS kcache_configured,
                           COALESCE(kcache.data_available, false)
                               AS cpu_data_available,
                           max(config.version) FILTER (WHERE config.extname = 'pg_wait_sampling') AS wait_version,
                           COALESCE(bool_or(config.enabled) FILTER (WHERE config.extname = 'pg_wait_sampling'), false) AS wait_configured,
                           COALESCE(wait_metric.data_available, false)
                               AS wait_data_available,
                           max(config.version) FILTER (WHERE config.extname = 'pg_qualstats') AS predicate_version,
                           COALESCE(bool_or(config.enabled) FILTER (WHERE config.extname = 'pg_qualstats'), false) AS predicate_configured,
                           join_cap.available AS join_configured,
                           COALESCE(join_data.data_available, false) AS join_data_available,
                           join_cap.status AS join_status,
                           join_cap.reason AS join_reason,
                           COALESCE(predicate_data.data_available, false)
                               AS predicate_data_available
                    FROM requested
                    JOIN "PoWA".powa_servers AS server
                      ON server.id > 0 AND server.frequency > 0
                    JOIN "PoWA".powa_databases AS database ON database.srvid = server.id
                    LEFT JOIN advisor.v_collector_health AS collector ON collector.server_id = server.id
                    LEFT JOIN "PoWA".powa_extension_config AS config ON config.srvid = server.id
                    LEFT JOIN join_capabilities AS join_cap ON join_cap.server_id = server.id
                    LEFT JOIN telemetry_data AS telemetry
                      ON telemetry.server_id = server.id
                     AND telemetry.database_id = database.oid
                    LEFT JOIN kcache_data AS kcache
                      ON kcache.server_id = server.id
                     AND kcache.database_id = database.oid
                    LEFT JOIN wait_data AS wait_metric
                      ON wait_metric.server_id = server.id
                     AND wait_metric.database_id = database.oid
                    LEFT JOIN predicate_data
                      ON predicate_data.server_id = server.id
                     AND predicate_data.database_id = database.oid
                    LEFT JOIN join_data
                      ON join_data.server_id = server.id
                     AND join_data.database_id = database.oid
                    WHERE database.dropped IS NULL
                      AND database.datname NOT IN ('powa', 'template0', 'template1')
                      AND (requested.server_id IS NULL OR server.id = requested.server_id)
                      AND (requested.database_id IS NULL OR database.oid = requested.database_id)
                    GROUP BY server.id, server.alias, database.oid, database.datname,
                             collector.status, collector.last_snapshot_at,
                             join_cap.available, join_cap.status, join_cap.reason,
                             telemetry.data_available, kcache.data_available,
                             wait_metric.data_available,
                             predicate_data.data_available, join_data.data_available
                    ORDER BY server.id, database.datname
                    """,
                    (interval, server_id, database_id),
                )
                rows = [dict(row) for row in await cursor.fetchall()]
        return rows

    async def database_optimize_rows(
        self,
        *,
        window: str,
        server_id: int | None,
        database_id: int | None,
        page: int,
        page_size: int,
        sort_by: str,
    ) -> tuple[list[dict[str, Any]], int, dict[str, Any]]:
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT candidate.*, server.alias AS server_alias,
                           database.datname AS database_name
                    FROM advisor.composite_index_candidates(
                        %s::interval, %s::integer, %s::oid, NULL::bigint
                    ) AS candidate
                    LEFT JOIN "PoWA".powa_servers AS server ON server.id = candidate.server_id
                    LEFT JOIN "PoWA".powa_databases AS database
                      ON database.srvid = candidate.server_id
                     AND database.oid = candidate.database_id
                    """,
                    (interval, server_id, database_id),
                )
                candidates = [dict(row) for row in await cursor.fetchall()]

        metrics = await self._query_metrics_snapshot(window)
        load_by_query = {
            (int(row["server_id"]), int(row["database_id"]), int(row["query_id"])):
                _as_float(row.get("total_exec_time_ms"))
            for row in metrics
            if (server_id is None or row.get("server_id") == server_id)
            and (database_id is None or row.get("database_id") == database_id)
        }
        grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = {}
        for candidate in candidates:
            key = (
                int(candidate["server_id"]),
                int(candidate["database_id"]),
                int(candidate["relation_id"]),
                str(candidate["method"]),
                tuple(int(value) for value in candidate["key_attnums"]),
            )
            grouped.setdefault(key, []).append(candidate)

        relation_ids = sorted({key[2] for key in grouped})
        write_by_relation: dict[tuple[int, int, int], dict[str, Any]] = {}
        if relation_ids:
            async with pool.connection() as connection:
                async with connection.cursor() as cursor:
                    await cursor.execute(
                        """
                        SELECT * FROM advisor.table_write_metrics(
                            %s::interval, %s::integer, %s::oid, %s::oid[]
                        )
                        """,
                        (interval, server_id, database_id, relation_ids),
                    )
                    for raw in await cursor.fetchall():
                        write = dict(raw)
                        write_by_relation[(
                            int(write["server_id"]),
                            int(write["database_id"]),
                            int(write["relation_id"]),
                        )] = write

        items: list[dict[str, Any]] = []
        all_affected_queries: set[tuple[int, int, int]] = set()
        for key, members in grouped.items():
            source_id, db_id, relation_id, method, attnums = key
            query_ids = sorted({int(row["query_id"]) for row in members})
            query_id_preview = sorted(
                query_ids,
                key=lambda query_id: (
                    -load_by_query.get((source_id, db_id, query_id), 0.0),
                    query_id,
                ),
            )[:OPTIMIZE_AFFECTED_QUERY_PREVIEW_SIZE]
            all_affected_queries.update((source_id, db_id, query_id) for query_id in query_ids)
            affected_load = sum(
                load_by_query.get((source_id, db_id, query_id), 0.0)
                for query_id in query_ids
            )
            representative = max(
                members,
                key=lambda row: (
                    load_by_query.get((source_id, db_id, int(row["query_id"])), 0.0),
                    -int(row["query_id"]),
                ),
            )
            group_id = uuid5(
                NAMESPACE_URL,
                f"postgresql-advisor:index:{source_id}:{db_id}:{relation_id}:{method}:"
                + ",".join(str(value) for value in attnums),
            )
            columns = list(representative["key_column_names"])
            safe_table = re.sub(r"[^A-Za-z0-9_]+", "_", str(representative["table_name"]))[:24]
            index_name = f"idx_advisor_{safe_table}_{group_id.hex[:8]}"
            quote = lambda value: '"' + str(value).replace('"', '""') + '"'
            create_sql = (
                f"CREATE INDEX CONCURRENTLY {quote(index_name)} ON "
                f"{quote(representative['schema_name'])}.{quote(representative['table_name'])} "
                f"USING btree ({', '.join(quote(column) for column in columns)});"
            )
            write = write_by_relation.get((source_id, db_id, relation_id))
            write_rows = None if write is None else int(write.get("write_rows") or 0)
            writes_per_hour = None if write is None else _optional_float(write.get("writes_per_hour"))
            if writes_per_hour is None:
                risk = "UNKNOWN"
            elif writes_per_hour >= 100_000:
                risk = "HIGH"
            elif writes_per_hour >= 10_000:
                risk = "MEDIUM"
            else:
                risk = "LOW"
            confidence_rank = {"LOW": 0, "MEDIUM": 1, "HIGH": 2}
            confidence = max(
                (str(row.get("confidence") or "LOW") for row in members),
                key=lambda value: confidence_rank.get(value, 0),
            )
            items.append({
                "group_id": str(group_id),
                "server_id": source_id,
                "server_alias": representative.get("server_alias"),
                "database_id": db_id,
                "database_name": representative.get("database_name"),
                "relation_id": relation_id,
                "schema_name": representative["schema_name"],
                "table_name": representative["table_name"],
                "method": method,
                "columns": columns,
                "ordering_rules": sorted({str(row["ordering_rule"]) for row in members}),
                "confidence": confidence,
                # Keep the aggregate exact while bounding one common-candidate
                # group from turning the API response (and browser DOM) into a
                # list of thousands of query identifiers. The highest-load
                # queries make the preview useful and deterministic.
                "affected_query_ids": [str(value) for value in query_id_preview],
                "affected_query_count": len(query_ids),
                "affected_load_ms": affected_load,
                "join_occurrences": sum(int(row.get("join_occurrences") or 0) for row in members),
                "filter_occurrences": sum(int(row.get("filter_occurrences") or 0) for row in members),
                "sample_count": sum(int(row.get("sample_count") or 0) for row in members),
                "observed_from": min(row["observed_from"] for row in members),
                "observed_to": max(row["observed_to"] for row in members),
                "representative_query_id": str(representative["query_id"]),
                "representative_candidate_id": str(representative["candidate_id"]),
                "create_index_sql": create_sql,
                "write_rows": write_rows,
                "writes_per_hour": writes_per_hour,
                "maintenance_risk": risk,
            })

        if sort_by == "affectedQueries":
            items.sort(key=lambda row: (-row["affected_query_count"], -row["affected_load_ms"], row["group_id"]))
        elif sort_by == "evidence":
            items.sort(key=lambda row: (-(row["join_occurrences"] + row["filter_occurrences"]), -row["affected_load_ms"], row["group_id"]))
        else:
            items.sort(key=lambda row: (-row["affected_load_ms"], -row["affected_query_count"], row["group_id"]))
        total = len(items)
        offset = (page - 1) * page_size
        summary = {
            "candidate_groups": total,
            "affected_queries": len(all_affected_queries),
            "affected_load_ms": sum(load_by_query.get(key, 0.0) for key in all_affected_queries),
        }
        return items[offset:offset + page_size], total, summary

    async def runtime_replay_fixture_status(
        self,
        *,
        candidate_ids: list[str],
        server_id: int,
        database_id: int,
        query_id: int,
        normalized_sql: str,
    ) -> set[str]:
        if not candidate_ids:
            return set()
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT candidate_id
                    FROM advisor.runtime_replay_fixture_status(
                        %s::uuid[], %s::integer, %s::oid, %s::bigint, %s::text
                    )
                    WHERE available
                    """,
                    (candidate_ids, server_id, database_id, query_id, normalized_sql),
                )
                return {str(row["candidate_id"]) for row in await cursor.fetchall()}

    async def runtime_replay_fixture(
        self,
        *,
        candidate_id: str,
        server_id: int,
        database_id: int,
        query_id: int,
        normalized_sql: str,
    ) -> dict[str, Any] | None:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.runtime_replay_fixture(
                        %s::uuid, %s::integer, %s::oid, %s::bigint, %s::text
                    )
                    """,
                    (candidate_id, server_id, database_id, query_id, normalized_sql),
                )
                row = await cursor.fetchone()
                return None if row is None else dict(row)

    async def annotate(
        self,
        *,
        server_id: int,
        database_id: int,
        query_id: int,
        status: str,
        note: str | None,
        actor: str,
    ) -> dict[str, Any]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT *
                    FROM advisor.upsert_query_annotation(
                        %s::integer, %s::oid, %s::bigint,
                        %s::text, %s::text, %s::text
                    )
                    """,
                    (server_id, database_id, query_id, status, note, actor),
                )
                row = dict(await cursor.fetchone())
        # Annotation columns are embedded in every window snapshot.  The
        # generation guard also prevents an older in-flight refresh from
        # repopulating the cache after this mutation.
        await self.invalidate_query_rows_cache()
        return row

    async def record_query_export_audit(
        self,
        *,
        actor: str,
        phase: str,
        details: dict[str, Any],
    ) -> None:
        normalized_phase = phase.upper()
        if normalized_phase not in {"REQUESTED", "COMPLETED"}:
            raise ValueError("Gecersiz CSV audit asamasi")
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT advisor.record_query_export_audit(%s::text, %s::text, %s::jsonb)
                    """,
                    (actor, normalized_phase, __import__("json").dumps(details)),
                )


repository = PowaRepository()
