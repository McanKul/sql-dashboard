from __future__ import annotations

import csv
import io
import time
from contextlib import suppress
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response, status

from app.config import WINDOW_INTERVALS, get_settings
from app.repositories.powa import repository, serialize_query
from app.schemas import (
    AnnotationUpdate,
    IndexAdvice,
    IndexEvaluationRequest,
    IndexResponse,
    InternalIndexEvaluationRequest,
    IoResponse,
    PredicateResponse,
)
from app.security import can_view_sql, request_role, require_admin
from app.services.evaluator import evaluate_index_candidate


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


def _cache_hit_percent(blocks_hit: int, blocks_read: int) -> float | None:
    total = blocks_hit + blocks_read
    if total <= 0:
        return None
    percent = 100.0 * blocks_hit / total
    # Büyük sayaçlarda floating-point yuvarlaması fiziksel okuma varken 100
    # üretebilir. API bu durumda kesin yüzde yüz iddiasında bulunmamalı.
    return min(percent, 99.999999) if blocks_read > 0 else percent


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


def _index_payload(row: dict[str, Any]) -> dict[str, Any]:
    blocks_read = int(row.get("blocks_read") or 0)
    blocks_hit = int(row.get("blocks_hit") or 0)
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "databaseId": row["database_id"],
        "databaseName": row.get("database_name"),
        "relationId": row["relation_id"],
        "tableName": row.get("table_name"),
        "indexId": row["index_id"],
        "indexName": row.get("index_name"),
        "sizeBytes": int(row.get("size_bytes") or 0),
        "scans": int(row.get("scans") or 0),
        "tuplesRead": int(row.get("tuples_read") or 0),
        "tuplesFetched": int(row.get("tuples_fetched") or 0),
        "blocksRead": blocks_read,
        "blocksHit": blocks_hit,
        "cacheHitPercent": _cache_hit_percent(blocks_hit, blocks_read),
        "lastScanAt": row.get("last_scan_at"),
        "signalLevel": row.get("signal_level"),
        "signal": row.get("signal"),
        "recommendation": row.get("recommendation"),
    }


def _predicate_payload(row: dict[str, Any]) -> dict[str, Any]:
    filter_ratio = row.get("filter_ratio")
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "databaseId": row["database_id"],
        "databaseName": row.get("database_name") or f"db-{row['database_id']}",
        "queryId": str(row["query_id"]),
        "qualId": str(row["qual_id"]),
        "relationId": row["relation_id"],
        "schemaName": row.get("schema_name") or "unknown",
        "tableName": row.get("table_name") or f"relation-{row['relation_id']}",
        "columns": list(row.get("column_names") or []),
        "operatorOids": [int(value) for value in (row.get("operator_oids") or [])],
        "evalType": row.get("eval_type") or "UNKNOWN",
        # pg_qualstats occurences is sampled predicate execution evidence.  It
        # must not be presented as the statement call count.
        "occurrences": int(row.get("occurrences") or 0),
        "rowsProcessed": int(row.get("rows_processed") or 0),
        "rowsFiltered": int(row.get("rows_filtered") or 0),
        "filterRatio": None if filter_ratio is None else round(float(filter_ratio), 6),
        "observedFrom": row["observed_from"],
        "observedTo": row["observed_to"],
        "sampleCount": int(row.get("sample_count") or 0),
        "signal": row.get("signal") or "INSUFFICIENT_DATA",
        "recommendation": row.get("recommendation") or "Daha fazla predicate verisi toplayin.",
    }


def _database_io_payload(row: dict[str, Any]) -> dict[str, Any]:
    blocks_read = int(row.get("blocks_read") or 0)
    blocks_hit = int(row.get("blocks_hit") or 0)
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "databaseId": row["database_id"],
        "databaseName": row.get("database_name"),
        "currentBackends": int(row.get("current_backends") or 0),
        "transactionsCommitted": int(row.get("transactions_committed") or 0),
        "transactionsRolledBack": int(row.get("transactions_rolled_back") or 0),
        "blocksRead": blocks_read,
        "blocksHit": blocks_hit,
        "cacheHitPercent": _cache_hit_percent(blocks_hit, blocks_read),
        "tempFiles": int(row.get("temp_files") or 0),
        "tempBytes": int(row.get("temp_bytes") or 0),
        "deadlocks": int(row.get("deadlocks") or 0),
        "blockReadTimeMs": round(float(row.get("block_read_time_ms") or 0), 2),
        "blockWriteTimeMs": round(float(row.get("block_write_time_ms") or 0), 2),
        "tuplesReturned": int(row.get("tuples_returned") or 0),
        "tuplesFetched": int(row.get("tuples_fetched") or 0),
        "tuplesInserted": int(row.get("tuples_inserted") or 0),
        "tuplesUpdated": int(row.get("tuples_updated") or 0),
        "tuplesDeleted": int(row.get("tuples_deleted") or 0),
    }


def _io_context_payload(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "backendType": row.get("backend_type"),
        "object": row.get("object"),
        "context": row.get("context"),
        "reads": int(row.get("reads") or 0),
        "readBytes": int(row.get("read_bytes") or 0),
        "readTimeMs": round(float(row.get("read_time_ms") or 0), 2),
        "writes": int(row.get("writes") or 0),
        "writeBytes": int(row.get("write_bytes") or 0),
        "writeTimeMs": round(float(row.get("write_time_ms") or 0), 2),
        "writebacks": int(row.get("writebacks") or 0),
        "writebackTimeMs": round(float(row.get("writeback_time_ms") or 0), 2),
        "extends": int(row.get("extends") or 0),
        "extendBytes": int(row.get("extend_bytes") or 0),
        "extendTimeMs": round(float(row.get("extend_time_ms") or 0), 2),
        "hits": int(row.get("hits") or 0),
        "evictions": int(row.get("evictions") or 0),
        "reuses": int(row.get("reuses") or 0),
        "fsyncs": int(row.get("fsyncs") or 0),
        "fsyncTimeMs": round(float(row.get("fsync_time_ms") or 0), 2),
    }


def _operation_payload(row: dict[str, Any]) -> dict[str, Any]:
    integer_fields = {
        "walRecords": "wal_records",
        "walFpi": "wal_fpi",
        "walBytes": "wal_bytes",
        "walBuffersFull": "wal_buffers_full",
        "walWrites": "wal_writes",
        "walSyncs": "wal_syncs",
        "timedCheckpoints": "timed_checkpoints",
        "requestedCheckpoints": "requested_checkpoints",
        "checkpointBuffersWritten": "checkpoint_buffers_written",
        "buffersClean": "buffers_clean",
        "maxwrittenClean": "maxwritten_clean",
        "buffersBackend": "buffers_backend",
        "buffersBackendFsync": "buffers_backend_fsync",
        "buffersAllocated": "buffers_allocated",
    }
    payload: dict[str, Any] = {
        "serverId": row["server_id"],
        "serverAlias": row.get("server_alias") or f"server-{row['server_id']}",
        "walWriteTimeMs": round(float(row.get("wal_write_time_ms") or 0), 2),
        "walSyncTimeMs": round(float(row.get("wal_sync_time_ms") or 0), 2),
        "checkpointWriteTimeMs": round(float(row.get("checkpoint_write_time_ms") or 0), 2),
        "checkpointSyncTimeMs": round(float(row.get("checkpoint_sync_time_ms") or 0), 2),
    }
    payload.update({key: int(row.get(column) or 0) for key, column in integer_fields.items()})
    return payload


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
    effective_page_size = min(page_size, settings.max_query_page_size)
    rows, total = await repository.query_rows(
        window=window,
        page=page,
        page_size=effective_page_size,
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
        "pageSize": effective_page_size,
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


@router.get("/queries/{query_id}/predicates", response_model=PredicateResponse)
async def query_predicates(
    query_id: int,
    window: Window = "24h",
    server_id: int = Query(alias="serverId"),
    database_id: int = Query(alias="databaseId"),
) -> dict[str, Any]:
    rows, raw_capability = await repository.predicate_evidence(
        window=window,
        server_id=server_id,
        database_id=database_id,
        query_id=query_id,
    )
    available = bool(raw_capability.get("available"))
    observed_from = min((row["observed_from"] for row in rows), default=None)
    observed_to = max((row["observed_to"] for row in rows), default=None)
    if not available:
        reason = "pg_qualstats bu kaynakta etkin degil; predicate/index adayi verisi uretilemiyor."
    elif not rows:
        reason = "pg_qualstats etkin, ancak secili pencerede bu sorgu icin predicate ornegi yok."
    else:
        reason = (
            "PoWA 5.2 repository hatti yalniz WHERE/filter predicate gecmisini tasir; "
            "JOIN verisi yoklugu sorguda JOIN olmadigi anlamina gelmez. Occurrence degeri "
            "orneklenen predicate calismasidir, statement cagri sayisi degildir."
        )
    return {
        "window": window,
        "queryId": str(query_id),
        "capability": {
            "available": available,
            "version": raw_capability.get("version"),
            "dataAvailable": bool(rows),
            "coverage": "WHERE_FILTER_ONLY",
            "joinsAvailable": False,
            "ddlGenerated": False,
            "reason": reason,
            "observedFrom": observed_from,
            "observedTo": observed_to,
        },
        "items": [_predicate_payload(row) for row in rows],
    }


@router.post("/queries/{query_id}/index-evaluations", response_model=IndexAdvice)
async def evaluate_query_index(
    query_id: int,
    payload: IndexEvaluationRequest,
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
) -> dict[str, Any]:
    if not can_view_sql(role):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="HypoPG plan dogrulamasi analyst yetkisi gerektirir.",
        )

    rows, raw_capability = await repository.predicate_evidence(
        window=window,
        server_id=payload.serverId,
        database_id=payload.databaseId,
        query_id=query_id,
    )
    if not raw_capability.get("available"):
        return {
            "status": "UNAVAILABLE",
            "reasonCode": "PREDICATE_TELEMETRY_UNAVAILABLE",
            "message": "Kaynakta pg_qualstats predicate telemetrisi etkin degil.",
            "ddlExecuted": False,
        }

    predicate = next(
        (
            row
            for row in rows
            if str(row["qual_id"]) == payload.qualId
            and int(row["relation_id"]) == payload.relationId
        ),
        None,
    )
    if predicate is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Predicate adayi secili pencerede bulunamadi.",
        )
    if predicate.get("signal") == "INSUFFICIENT_DATA":
        return {
            "status": "INSUFFICIENT",
            "reasonCode": "INSUFFICIENT_PREDICATE_EVIDENCE",
            "message": "HypoPG dogrulamasi icin daha fazla predicate ornegi birikmeli.",
            "ddlExecuted": False,
        }
    if predicate.get("eval_type") != "FILTER" or predicate.get("signal") not in {
        "INDEX_CANDIDATE",
        "REVIEW",
    }:
        return {
            "status": "NO_IMPROVEMENT",
            "reasonCode": "NO_NEW_BTREE_CANDIDATE",
            "message": "Bu predicate icin yeni tek kolonlu B-tree adayi uretilmedi.",
            "ddlExecuted": False,
        }

    columns = list(predicate.get("column_names") or [])
    if predicate.get("schema_name") == "unknown" or len(columns) != 1:
        return {
            "status": "UNSAFE",
            "reasonCode": "UNRESOLVED_OR_COMPOSITE_PREDICATE",
            "message": "Canli kaynakta tek kolonlu predicate kimligi guvenle cozumlenemedi.",
            "ddlExecuted": False,
        }

    operator_oids = [int(value) for value in (predicate.get("operator_oids") or [])]
    if not operator_oids:
        return {
            "status": "UNSAFE",
            "reasonCode": "UNRESOLVED_OPERATOR",
            "message": "Predicate operatoru canli katalogda guvenle dogrulanamadi.",
            "ddlExecuted": False,
        }

    query = await repository.query_by_id(
        query_id=query_id,
        window=window,
        server_id=payload.serverId,
        database_id=payload.databaseId,
    )
    if query is None:
        raise HTTPException(status_code=404, detail="Sorgu secili pencerede bulunamadi.")

    request = InternalIndexEvaluationRequest(
        serverId=payload.serverId,
        serverAlias=str(predicate.get("server_alias") or f"server-{payload.serverId}"),
        databaseId=payload.databaseId,
        databaseName=str(predicate.get("database_name") or f"db-{payload.databaseId}"),
        queryId=str(query_id),
        normalizedSql=str(query["sql_text"]),
        qualId=payload.qualId,
        relationId=payload.relationId,
        schemaName=str(predicate["schema_name"]),
        tableName=str(predicate["table_name"]),
        columns=columns,
        operatorOids=operator_oids,
        occurrences=int(predicate.get("occurrences") or 0),
        rowsProcessed=int(predicate.get("rows_processed") or 0),
        filterRatio=(
            None if predicate.get("filter_ratio") is None else float(predicate["filter_ratio"])
        ),
        sampleCount=int(predicate.get("sample_count") or 0),
    )
    return await evaluate_index_candidate(request)


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
    rows, _ = await repository.query_rows(window=window, page_size=10, sort_by="impact")
    summary = await repository.overview_summary(window=window)
    collectors = await repository.collector_health()
    collector_summary = _summarize_collectors(collectors)
    trend = await repository.trend(window=window)
    return {
        "window": window,
        "cards": {
            "totalDbTimeMs": round(float(summary.get("total_db_time_ms") or 0), 2),
            "trackedQueries": int(summary.get("tracked_queries") or 0),
            "criticalQueries": int(summary.get("critical_queries") or 0),
            "regressions": int(summary.get("regressions") or 0),
            "collectorLagSeconds": collector_summary.get("lag_seconds"),
        },
        "topQueries": [serialize_query(row, sql_visible=can_view_sql(role)) for row in rows],
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


@router.get("/indexes", response_model=IndexResponse)
async def indexes(
    window: Window = "24h",
    server_id: int | None = Query(default=None, alias="serverId"),
    database_id: int | None = Query(default=None, alias="databaseId"),
) -> dict[str, Any]:
    rows, summary = await repository.index_rows(
        window=window,
        server_id=server_id,
        database_id=database_id,
    )
    return {
        "window": window,
        "summary": {
            "indexesObserved": int(summary.get("indexes_observed") or 0),
            "candidateSignals": int(summary.get("candidate_signals") or 0),
            "totalSizeBytes": int(summary.get("total_size_bytes") or 0),
            "noScanSizeBytes": int(summary.get("no_scan_size_bytes") or 0),
        },
        "items": [_index_payload(row) for row in rows],
    }


@router.get("/io", response_model=IoResponse)
async def io_telemetry(
    window: Window = "24h",
    server_id: int | None = Query(default=None, alias="serverId"),
    database_id: int | None = Query(default=None, alias="databaseId"),
) -> dict[str, Any]:
    database_rows, context_rows, server_rows = await repository.io_telemetry(
        window=window,
        server_id=server_id,
        database_id=database_id,
    )
    databases = [_database_io_payload(row) for row in database_rows]
    contexts = [_io_context_payload(row) for row in context_rows]
    servers = [_operation_payload(row) for row in server_rows]
    blocks_read = sum(row["blocksRead"] for row in databases)
    blocks_hit = sum(row["blocksHit"] for row in databases)
    return {
        "window": window,
        "summary": {
            "reads": sum(row["reads"] for row in contexts),
            "writes": sum(row["writes"] for row in contexts),
            "readBytes": sum(row["readBytes"] for row in contexts),
            "writeBytes": sum(row["writeBytes"] for row in contexts),
            "extendBytes": sum(row["extendBytes"] for row in contexts),
            "cacheHits": blocks_hit,
            "cacheHitPercent": _cache_hit_percent(blocks_hit, blocks_read),
            "tempBytes": sum(row["tempBytes"] for row in databases),
            "walBytes": sum(row["walBytes"] for row in servers),
            "checkpoints": sum(
                row["timedCheckpoints"] + row["requestedCheckpoints"] for row in servers
            ),
            "checkpointWriteTimeMs": round(
                sum(row["checkpointWriteTimeMs"] for row in servers), 2
            ),
            "backendWrites": sum(row["buffersBackend"] for row in servers),
        },
        "capabilities": [
            {
                "key": "databaseStats",
                "available": True,
                "resetEpochAware": True,
                "source": "PoWA pg_stat_database",
            },
            {
                "key": "statIo",
                "available": True,
                "resetEpochAware": True,
                "source": "PoWA pg_stat_io",
            },
            {
                "key": "wal",
                "available": True,
                "resetEpochAware": True,
                "source": "PoWA pg_stat_wal",
            },
            {
                "key": "checkpointAndBgwriter",
                "available": True,
                "resetEpochAware": False,
                "source": "PoWA pg_stat_checkpointer + pg_stat_bgwriter",
                "limitation": (
                    "Kaynak kayit tipleri stats_reset zamani tasimiyor; sayac azalmasi olan "
                    "snapshot sifir katkili kabul edilir."
                ),
            },
        ],
        "databases": databases,
        "contexts": contexts,
        "servers": servers,
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
            "cpu_user_time_ms",
            "cpu_system_time_ms",
            "cpu_total_time_ms",
            "cpu_percent_of_exec_time",
            "filesystem_reads_bytes",
            "filesystem_writes_bytes",
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
                row["cpu_user_time_ms"],
                row["cpu_system_time_ms"],
                row["cpu_total_time_ms"],
                row["cpu_percent_of_exec_time"],
                row["filesystem_reads_bytes"],
                row["filesystem_writes_bytes"],
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
