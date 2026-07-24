from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime
from decimal import Decimal
from typing import Any

from app.config import WINDOW_BUCKETS, WINDOW_INTERVALS
from app.db import pool


SORT_COLUMNS = {
    "impact": "impact_score",
    "totalTime": "total_exec_time_ms",
    "meanTime": "mean_exec_time_ms",
    "calls": "calls",
    "regression": "regression_percent",
    "reads": "shared_blocks_read",
}


def interval_for(window: str) -> str:
    try:
        return WINDOW_INTERVALS[window]
    except KeyError as exc:
        raise ValueError(f"Gecersiz zaman araligi: {window}") from exc


def _as_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    if isinstance(value, Decimal):
        return float(value)
    return float(value)


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
    if _as_float(row.get("regression_percent")) >= 20 and int(row.get("previous_calls") or 0) >= 5:
        findings.append("Onceki es doneme gore ortalama calisma suresi geriledi.")
    if int(row.get("temp_blocks_written") or 0) > 0:
        findings.append("Gecici blok yazimi var; siralama/hash bellek kullanimi incelenmeli.")
    if _as_float(row.get("wal_bytes")) > 1_000_000:
        findings.append("WAL uretimi yuksek.")
    if not findings:
        findings.append("Belirgin bir risk esigi asilmadi; trend izlenmeli.")
    return findings


def serialize_query(row: Mapping[str, Any], *, sql_visible: bool) -> dict[str, Any]:
    raw_sql = str(row.get("sql_text") or "")
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
        "previousCalls": int(row.get("previous_calls") or 0),
        "previousMeanExecTimeMs": round(_as_float(row.get("previous_mean_exec_time_ms")), 2),
        "regressionPercent": round(_as_float(row.get("regression_percent")), 2),
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

    async def collector_health(self) -> list[dict[str, Any]]:
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
                    ORDER BY server_id
                    """
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
        interval = interval_for(window)
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
            conditions.extend(["regression_percent > 0", "previous_calls >= 5"])

        where_sql = " AND ".join(conditions)
        order_column = SORT_COLUMNS.get(sort_by, SORT_COLUMNS["impact"])
        offset = (page - 1) * page_size

        count_query = f"""
            SELECT count(*) AS total
            FROM advisor.query_metrics(%s::interval)
            WHERE {where_sql}
        """
        data_query = f"""
            SELECT metrics.*, servers.alias AS server_alias
            FROM advisor.query_metrics(%s::interval) AS metrics
            LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
            WHERE {where_sql}
            ORDER BY {order_column} DESC NULLS LAST, query_id
            LIMIT %s OFFSET %s
        """

        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(count_query, [interval, *filters])
                total = int((await cursor.fetchone())["total"])
                await cursor.execute(data_query, [interval, *filters, page_size, offset])
                rows = [dict(row) for row in await cursor.fetchall()]
        return rows, total

    async def overview_summary(self, *, window: str) -> dict[str, Any]:
        """Aggregate every tracked query; pagination must never affect cards."""
        interval = interval_for(window)
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT
                        COALESCE(sum(total_exec_time_ms), 0)::double precision AS total_db_time_ms,
                        count(*)::bigint AS tracked_queries,
                        count(*) FILTER (WHERE priority = 'CRITICAL')::bigint AS critical_queries,
                        count(*) FILTER (
                            WHERE regression_percent > 0 AND previous_calls >= 5
                        )::bigint AS regressions
                    FROM advisor.query_metrics(%s::interval)
                    """,
                    (interval,),
                )
                return dict(await cursor.fetchone())

    async def query_by_id(
        self,
        *,
        query_id: int,
        window: str,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> dict[str, Any] | None:
        interval = interval_for(window)
        clauses = ["query_id = %s"]
        params: list[Any] = [interval, query_id]
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
                    SELECT metrics.*, servers.alias AS server_alias
                    FROM advisor.query_metrics(%s::interval) AS metrics
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = metrics.server_id
                    WHERE {' AND '.join(clauses)}
                    ORDER BY impact_score DESC
                    LIMIT 1
                    """,
                    params,
                )
                row = await cursor.fetchone()
                return dict(row) if row else None

    async def trend(
        self,
        *,
        window: str,
        query_id: int | None = None,
        server_id: int | None = None,
        database_id: int | None = None,
    ) -> list[dict[str, Any]]:
        interval = interval_for(window)
        bucket = WINDOW_BUCKETS[window]
        clauses = ["sample_at >= now() - %s::interval"]
        params: list[Any] = [bucket, interval, interval]
        if query_id is not None:
            clauses.append("query_id = %s")
            params.append(query_id)
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
                    SELECT date_bin(%s::interval, sample_at, timestamptz '2000-01-01') AS timestamp,
                           sum(total_exec_time_ms)::double precision AS total_exec_time_ms,
                           sum(calls)::bigint AS calls
                    FROM advisor.query_deltas(now() - %s::interval) AS deltas
                    JOIN "PoWA".powa_databases AS db
                      ON db.srvid = deltas.server_id AND db.oid = deltas.database_id
                    WHERE db.datname <> 'powa' AND {' AND '.join(clauses)}
                    GROUP BY 1
                    ORDER BY 1
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

    async def table_health(self) -> list[dict[str, Any]]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT health.*, servers.alias AS server_alias
                    FROM advisor.v_table_health AS health
                    LEFT JOIN "PoWA".powa_servers AS servers ON servers.id = health.server_id
                    ORDER BY
                        CASE signal_level
                            WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2
                            WHEN 'NOTICE' THEN 3 ELSE 4 END,
                        dead_tuples DESC
                    LIMIT 200
                    """
                )
                return [dict(row) for row in await cursor.fetchall()]

    async def long_transactions(self) -> list[dict[str, Any]]:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    SELECT * FROM advisor.v_long_transactions
                    ORDER BY age_seconds DESC
                    LIMIT 100
                    """
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
            async with connection.transaction():
                async with connection.cursor() as cursor:
                    await cursor.execute("SELECT set_config('app.actor', %s, true)", (actor,))
                    await cursor.execute(
                        """
                        INSERT INTO advisor.query_annotations
                            (server_id, database_id, query_id, status, note, updated_by)
                        VALUES (%s, %s, %s, %s, %s, %s)
                        ON CONFLICT (server_id, database_id, query_id)
                        DO UPDATE SET status = EXCLUDED.status,
                                      note = EXCLUDED.note,
                                      updated_by = EXCLUDED.updated_by,
                                      updated_at = now()
                        RETURNING server_id, database_id, query_id, status, note,
                                  updated_by, updated_at
                        """,
                        (server_id, database_id, query_id, status, note, actor),
                    )
                    return dict(await cursor.fetchone())

    async def audit_export(self, *, actor: str, details: dict[str, Any]) -> None:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute(
                    """
                    INSERT INTO advisor.audit_log(actor, action, object_type, object_key, details)
                    VALUES (%s, 'QUERIES_EXPORTED', 'query_collection', 'queries.csv', %s::jsonb)
                    """,
                    (actor, __import__("json").dumps(details)),
                )


repository = PowaRepository()
