from __future__ import annotations

import csv
import io
import time
from contextlib import suppress
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response, status

from app.config import WINDOW_INTERVALS, get_settings
from app.repositories.powa import repository, serialize_query
from app.schemas import AnnotationUpdate
from app.security import can_view_sql, request_role, require_admin


router = APIRouter(prefix="/api/v1")
settings = get_settings()
Window = Literal["1h", "24h", "7d", "30d"]


COLLECTOR_STATUS_RANK = {
    "HEALTHY": 0,
    "STARTING": 1,
    "UNKNOWN": 2,
    "STALE": 3,
    "DEGRADED": 4,
}


def _collector_payload(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "serverId": row["server_id"],
        "alias": row.get("alias"),
        "hostname": row.get("hostname"),
        "port": row.get("port"),
        "frequencySeconds": row.get("frequency"),
        "retention": row.get("retention"),
        "lastSnapshotAt": row.get("last_snapshot_at"),
        "lagSeconds": row.get("lag_seconds"),
        "errors": row.get("errors") or [],
        "status": row.get("status"),
    }


def _summarize_collectors(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Return one honest fleet-level status without hiding a troubled source."""
    if not rows:
        return {
            "server_id": 0,
            "alias": "Henüz kaynak yok",
            "hostname": None,
            "port": None,
            "frequency": None,
            "retention": None,
            "last_snapshot_at": None,
            "lag_seconds": None,
            "errors": [],
            "status": "STARTING",
        }

    worst = max(rows, key=lambda row: COLLECTOR_STATUS_RANK.get(str(row.get("status")), 2))
    snapshots = [row["last_snapshot_at"] for row in rows if row.get("last_snapshot_at") is not None]
    lags = [float(row["lag_seconds"]) for row in rows if row.get("lag_seconds") is not None]
    errors = [
        f"{row.get('alias') or row.get('hostname') or row.get('server_id')}: {error}"
        for row in rows
        for error in (row.get("errors") or [])
    ]
    retentions = {str(row.get("retention")) for row in rows if row.get("retention") is not None}
    return {
        "server_id": rows[0]["server_id"] if len(rows) == 1 else 0,
        "alias": (rows[0].get("alias") if len(rows) == 1 else f"{len(rows)} PostgreSQL kaynağı"),
        "hostname": rows[0].get("hostname") if len(rows) == 1 else None,
        "port": rows[0].get("port") if len(rows) == 1 else None,
        "frequency": min((row.get("frequency") for row in rows if row.get("frequency") is not None), default=None),
        "retention": retentions.pop() if len(retentions) == 1 else "Kaynağa göre değişir",
        # En eski son snapshot ve en büyük gecikme, filonun en geride kalan
        # kaynağını temsil eder; taze bir kaynak diğerini gizleyemez.
        "last_snapshot_at": min(snapshots) if snapshots else None,
        "lag_seconds": max(lags) if lags else None,
        "errors": errors,
        "status": worst.get("status") or "UNKNOWN",
    }


def _table_payload(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "databaseId": row["database_id"],
        "databaseName": row.get("database_name"),
        "relationId": row["relation_id"],
        "relationName": row.get("relation_name"),
        "sampleAt": row.get("sample_at"),
        "tableSizeBytes": row.get("table_size_bytes") or 0,
        "seqScan": row.get("seq_scan") or 0,
        "seqTuplesRead": row.get("seq_tup_read") or 0,
        "indexScan": row.get("idx_scan") or 0,
        "liveTuples": row.get("live_tuples") or 0,
        "deadTuples": row.get("dead_tuples") or 0,
        "deadTuplePercent": row.get("dead_tuple_percent") or 0,
        "lastAutovacuum": row.get("last_autovacuum"),
        "signalLevel": row.get("signal_level"),
        "recommendation": row.get("recommendation"),
    }


@router.get("/health")
async def health(response: Response) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        database = await repository.ping()
        collectors = await repository.collector_health()
    except Exception as exc:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {
            "status": "unhealthy",
            "api": "healthy",
            "repository": "unreachable",
            "collector": "unknown",
            "detail": type(exc).__name__,
        }

    collector_summary = _summarize_collectors(collectors)
    collector_status = collector_summary["status"]
    overall = "healthy" if collector_status == "HEALTHY" else "degraded"
    return {
        "status": overall,
        "api": "healthy",
        "repository": "healthy",
        "collector": collector_status.lower(),
        "collectors": [_collector_payload(row) for row in collectors],
        "database": {
            "name": database["database_name"],
            "postgresVersion": database["postgres_version"],
            "powaVersion": database["powa_version"],
        },
        "responseTimeMs": round((time.perf_counter() - started) * 1000, 2),
    }


@router.get("/servers")
async def servers() -> dict[str, Any]:
    rows = await repository.servers()
    return {
        "items": [
            {
                "id": row["id"],
                "alias": row["alias"],
                "hostname": row["hostname"],
                "port": row["port"],
                "database": row["dbname"],
                "frequencySeconds": row["frequency"],
                "retention": row["retention"],
                "version": row["version"],
            }
            for row in rows
        ]
    }


@router.get("/databases")
async def databases(server_id: int | None = Query(default=None, alias="serverId")) -> dict[str, Any]:
    rows = await repository.databases(server_id)
    return {
        "items": [
            {
                "serverId": row["server_id"],
                "databaseId": row["database_id"],
                "name": row["name"],
            }
            for row in rows
        ]
    }


@router.get("/queries")
async def queries(
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200, alias="pageSize"),
    search: str | None = Query(default=None, max_length=300),
    priority: str | None = None,
    server_id: int | None = Query(default=None, alias="serverId"),
    database_id: int | None = Query(default=None, alias="databaseId"),
    min_calls: int = Query(default=0, ge=0, alias="minCalls"),
    min_duration_ms: float = Query(default=0, ge=0, alias="minDurationMs"),
    sort_by: str = Query(default="impact", alias="sort"),
) -> dict[str, Any]:
    rows, total = await repository.query_rows(
        window=window,
        page=page,
        page_size=min(page_size, settings.max_query_page_size),
        search=search,
        priority=priority,
        server_id=server_id,
        database_id=database_id,
        min_calls=min_calls,
        min_duration_ms=min_duration_ms,
        sort_by=sort_by,
    )
    visible = can_view_sql(role)
    return {
        "items": [serialize_query(row, sql_visible=visible) for row in rows],
        "page": page,
        "pageSize": page_size,
        "total": total,
        "window": window,
    }


@router.get("/queries/{query_id}")
async def query_detail(
    query_id: int,
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
    server_id: int | None = Query(default=None, alias="serverId"),
    database_id: int | None = Query(default=None, alias="databaseId"),
) -> dict[str, Any]:
    row = await repository.query_by_id(
        query_id=query_id,
        window=window,
        server_id=server_id,
        database_id=database_id,
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Sorgu bu zaman araliginda bulunamadi.")
    item = serialize_query(row, sql_visible=can_view_sql(role))
    trend = await repository.trend(
        window=window,
        query_id=query_id,
        server_id=row["server_id"],
        database_id=row["database_id"],
    )
    item.update(
        {
            "trend": [
                {
                    "timestamp": point["timestamp"],
                    "totalExecTimeMs": round(float(point["total_exec_time_ms"] or 0), 2),
                    "calls": point["calls"] or 0,
                }
                for point in trend
            ],
            "comparison": {
                "currentMeanMs": item["meanExecTimeMs"],
                "previousMeanMs": item["previousMeanExecTimeMs"],
                "regressionPercent": item["regressionPercent"],
                "currentCalls": item["calls"],
                "previousCalls": item["previousCalls"],
            },
        }
    )
    return item


@router.patch("/queries/{query_id}/annotation")
async def update_annotation(
    query_id: int,
    payload: AnnotationUpdate,
    server_id: int = Query(alias="serverId"),
    database_id: int = Query(alias="databaseId"),
) -> dict[str, Any]:
    row = await repository.annotate(
        server_id=server_id,
        database_id=database_id,
        query_id=query_id,
        status=payload.status,
        note=payload.note,
        actor=payload.updated_by,
    )
    return {
        "serverId": row["server_id"],
        "databaseId": row["database_id"],
        "queryId": str(row["query_id"]),
        "status": row["status"],
        "note": row["note"],
        "updatedBy": row["updated_by"],
        "updatedAt": row["updated_at"],
    }


@router.get("/regressions")
async def regressions(
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200, alias="pageSize"),
) -> dict[str, Any]:
    rows, total = await repository.query_rows(
        window=window,
        page=page,
        page_size=page_size,
        sort_by="regression",
        regressions_only=True,
    )
    return {
        "items": [serialize_query(row, sql_visible=can_view_sql(role)) for row in rows],
        "page": page,
        "pageSize": page_size,
        "total": total,
        "window": window,
    }


@router.get("/overview")
async def overview(
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
) -> dict[str, Any]:
    rows, total = await repository.query_rows(window=window, page_size=200, sort_by="impact")
    collectors = await repository.collector_health()
    collector_summary = _summarize_collectors(collectors)
    trend = await repository.trend(window=window)
    top = rows[:10]
    return {
        "window": window,
        "cards": {
            "totalDbTimeMs": round(sum(float(row.get("total_exec_time_ms") or 0) for row in rows), 2),
            "trackedQueries": total,
            "criticalQueries": sum(1 for row in rows if row.get("priority") == "CRITICAL"),
            "regressions": sum(
                1
                for row in rows
                if float(row.get("regression_percent") or 0) > 0
                and int(row.get("previous_calls") or 0) >= 5
            ),
            "collectorLagSeconds": collector_summary.get("lag_seconds"),
        },
        "topQueries": [serialize_query(row, sql_visible=can_view_sql(role)) for row in top],
        "trend": [
            {
                "timestamp": point["timestamp"],
                "totalExecTimeMs": round(float(point["total_exec_time_ms"] or 0), 2),
                "calls": point["calls"] or 0,
            }
            for point in trend
        ],
        "collector": _collector_payload(collector_summary),
        "collectors": [_collector_payload(row) for row in collectors],
    }


@router.get("/tables")
@router.get("/system-health")
async def system_health() -> dict[str, Any]:
    rows = await repository.table_health()
    transactions = await repository.long_transactions()
    items = [_table_payload(row) for row in rows]
    return {
        "summary": {
            "tablesObserved": len(items),
            "critical": sum(1 for row in items if row["signalLevel"] == "CRITICAL"),
            "warnings": sum(1 for row in items if row["signalLevel"] == "WARNING"),
            "notices": sum(1 for row in items if row["signalLevel"] == "NOTICE"),
        },
        "capabilities": [
            {"key": "seqScan", "label": "Seq Scan", "available": True, "source": "PoWA pg_stat_all_tables"},
            {"key": "deadTuple", "label": "Dead tuple", "available": True, "source": "PoWA pg_stat_all_tables"},
            {"key": "autovacuum", "label": "Autovacuum", "available": True, "source": "PoWA pg_stat_all_tables"},
            {"key": "longTransaction", "label": "Uzun transaction", "available": True, "source": "PoWA pg_stat_activity"},
            {
                "key": "lockWait",
                "label": "Lock bekleme",
                "available": False,
                "source": "PostgreSQL 19 pg_stat_lock",
                "reason": "PoWA 5.2 pg_stat_lock veri kaynagi PostgreSQL 19 gerektiriyor.",
            },
        ],
        "items": items,
        "longTransactions": [
            {
                "serverId": row["server_id"],
                "databaseId": row["database_id"],
                "databaseName": row["database_name"],
                "pid": row["pid"],
                "applicationName": row["application_name"],
                "state": row["state"],
                "transactionStartedAt": row["transaction_started_at"],
                "observedAt": row["observed_at"],
                "ageSeconds": round(float(row["age_seconds"] or 0), 2),
            }
            for row in transactions
        ],
    }


@router.get("/operations")
async def operations() -> dict[str, Any]:
    database = await repository.ping()
    collectors = await repository.collector_health()
    collector = _summarize_collectors(collectors)
    collector_state = collector["status"]
    source_services = [
        {
            "name": f"PostgreSQL kaynak · {row.get('alias') or row.get('hostname') or row['server_id']}",
            "service": f"source-{row['server_id']}",
            "status": row.get("status") or "UNKNOWN",
        }
        for row in collectors
    ]
    return {
        "architecture": {
            "host": "Tek Docker/OrbStack hostu",
            "source": {"count": len(collectors), "role": "İzlenen PostgreSQL kaynakları + pg_stat_statements"},
            "repository": {"service": "repository-db", "hostPort": 5433, "role": "90 gun PoWA gecmisi"},
            "dataFlow": ["PostgreSQL kaynakları", "collector", "repository-db", "api", "web"],
            "apiSourceConnection": False,
        },
        "services": [
            *source_services,
            {"name": "PostgreSQL repository", "service": "repository-db", "status": "HEALTHY"},
            {"name": "PoWA Collector", "service": "collector", "status": collector_state},
            {"name": "FastAPI", "service": "api", "status": "HEALTHY"},
            {"name": "Web UI", "service": "web", "status": "HEALTHY"},
        ],
        "collector": _collector_payload(collector),
        "collectors": [_collector_payload(row) for row in collectors],
        "repository": {
            "postgresVersion": database["postgres_version"],
            "powaVersion": database["powa_version"],
            "sizeBytes": database["repository_size_bytes"],
            "retentionDays": settings.retention_days,
        },
    }


@router.get("/export/queries.csv")
async def export_queries(
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
    x_advisor_actor: str = Header(default="admin", alias="X-Advisor-Actor"),
) -> Response:
    require_admin(role)
    rows, _ = await repository.query_rows(window=window, page_size=200, sort_by="impact")
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(
        [
            "server_id",
            "database_id",
            "query_id",
            "sql",
            "calls",
            "total_exec_time_ms",
            "mean_exec_time_ms",
            "impact_score",
            "priority",
            "regression_percent",
            "status",
        ]
    )
    for row in rows:
        writer.writerow(
            [
                row["server_id"],
                row["database_id"],
                row["query_id"],
                row["sql_text"],
                row["calls"],
                row["total_exec_time_ms"],
                row["mean_exec_time_ms"],
                row["impact_score"],
                row["priority"],
                row["regression_percent"],
                row["review_status"],
            ]
        )
    await repository.audit_export(actor=x_advisor_actor, details={"window": window, "rows": len(rows)})
    return Response(
        content=output.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="queries-{window}.csv"'},
    )
