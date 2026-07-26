from __future__ import annotations

import csv
import io
import time
from contextlib import aclosing, suppress
from typing import Annotated, Any, Literal
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from fastapi.responses import StreamingResponse

from app.config import WINDOW_INTERVALS, get_settings
from app.clone_evaluator import (
    CloneIndexEvaluationResult,
    InternalCloneIndexEvaluationRequest,
    ValidatedCloneIndexCandidate,
    _production_index_sql,
)
from app.evaluator import _proposed_index_name
from app.repositories.powa import repository, serialize_query
from app.schemas import (
    AnnotationUpdate,
    CompositeIndexEvaluationRequest,
    IndexAdvice,
    IndexEvaluationRequest,
    IndexResponse,
    InternalIndexEvaluationRequest,
    InternalQueryExplainAnalyzeRequest,
    IoResponse,
    PredicateResponse,
    QueryExplainAnalyzeRequest,
    QueryExplainAnalyzeResult,
    RuntimeIndexValidationRequest,
)
from app.security import (
    RequestPrincipal,
    can_view_sql,
    request_admin_principal,
    request_annotator_principal,
    request_role,
)
from app.services.evaluator import evaluate_index_candidate, explain_query_on_source
from app.services.clone_evaluator import validate_index_on_clone
from app.services.capabilities import evaluator_health
from app.version import APPLICATION_VERSION, EXPECTED_MIGRATION


router = APIRouter(prefix="/api/v1")
settings = get_settings()
Window = Literal["1h", "24h", "7d", "30d"]


async def _scope_payload(
    *,
    window: str | None,
    server_id: int | None,
    database_id: int | None,
) -> dict[str, Any]:
    if database_id is not None and server_id is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="databaseId kullanildiginda serverId zorunludur.",
        )
    if server_id is None:
        return {
            "serverId": None,
            "serverAlias": None,
            "databaseId": None,
            "databaseName": None,
            "window": window,
        }
    resolved = await repository.resolve_scope(
        server_id=server_id,
        database_id=database_id,
    )
    if resolved is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Secilen PostgreSQL kaynak/veritabani kapsami bulunamadi.",
        )
    return {
        "serverId": server_id,
        "serverAlias": resolved.get("server_alias"),
        "databaseId": database_id,
        "databaseName": resolved.get("database_name") if database_id is not None else None,
        "window": window,
    }


def _release_payload(row: dict[str, Any]) -> dict[str, Any]:
    current = str(row.get("current_migration") or "")
    return {
        "applicationVersion": APPLICATION_VERSION,
        "migration": {
            "current": current or None,
            "expected": EXPECTED_MIGRATION,
            "appliedCount": int(row.get("applied_count") or 0),
            "latestAppliedAt": row.get("latest_applied_at"),
            "upToDate": current == EXPECTED_MIGRATION,
        },
    }

QUERY_CSV_COLUMNS = (
    ("server_id", "server_id"),
    ("database_id", "database_id"),
    ("query_id", "query_id"),
    ("sql", "sql_text"),
    ("calls", "calls"),
    ("total_exec_time_ms", "total_exec_time_ms"),
    ("mean_exec_time_ms", "mean_exec_time_ms"),
    ("cpu_user_time_ms", "cpu_user_time_ms"),
    ("cpu_system_time_ms", "cpu_system_time_ms"),
    ("cpu_total_time_ms", "cpu_total_time_ms"),
    ("cpu_percent_of_exec_time", "cpu_percent_of_exec_time"),
    ("filesystem_reads_bytes", "filesystem_reads_bytes"),
    ("filesystem_writes_bytes", "filesystem_writes_bytes"),
    ("wait_total_samples", "wait_total_samples"),
    ("dominant_wait_category", "dominant_wait_category"),
    ("dominant_wait_event", "dominant_wait_event"),
    ("dominant_wait_share_percent", "dominant_wait_share_percent"),
    ("impact_score", "impact_score"),
    ("priority", "priority"),
    ("regression_percent", "regression_percent"),
    ("status", "review_status"),
)


def _query_csv_chunk(rows: list[dict[str, Any]], *, include_header: bool = False) -> str:
    """Serialize one bounded database batch, never the complete export."""
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    if include_header:
        writer.writerow([header for header, _ in QUERY_CSV_COLUMNS])
    writer.writerows(
        [row.get(key) for _, key in QUERY_CSV_COLUMNS]
        for row in rows
    )
    return output.getvalue()


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


def _join_payload(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "serverId": row["server_id"],
        "serverAlias": row["server_alias"],
        "databaseId": row["database_id"],
        "databaseName": row["database_name"],
        "queryId": str(row["query_id"]),
        "qualId": str(row["qual_id"]),
        "qualNodeId": str(row["qual_node_id"]),
        "leftRelationId": row["left_relation_id"],
        "leftSchemaName": row["left_schema_name"],
        "leftTableName": row["left_table_name"],
        "leftColumnName": row["left_column_name"],
        "rightRelationId": row["right_relation_id"],
        "rightSchemaName": row["right_schema_name"],
        "rightTableName": row["right_table_name"],
        "rightColumnName": row["right_column_name"],
        "operatorOid": int(row["operator_oid"]),
        "operatorName": row.get("operator_name"),
        "btreeStrategy": row.get("btree_strategy"),
        "occurrences": int(row.get("occurrences") or 0),
        "rowsProcessed": int(row.get("rows_processed") or 0),
        "sampleCount": int(row.get("sample_count") or 0),
        "observedFrom": row["observed_from"],
        "observedTo": row["observed_to"],
        "signal": row["signal"],
        "scoreIncluded": False,
    }


def _candidate_payload(row: dict[str, Any]) -> dict[str, Any]:
    ratio = row.get("filter_ratio")
    return {
        "candidateId": str(row["candidate_id"]),
        "serverId": row["server_id"],
        "databaseId": row["database_id"],
        "queryId": str(row["query_id"]),
        "relationId": row["relation_id"],
        "schemaName": row["schema_name"],
        "tableName": row["table_name"],
        "method": row["method"],
        "columns": list(row["key_column_names"]),
        "operatorOids": [int(value) for value in row["operator_oids"]],
        "orderingRule": row["ordering_rule"],
        "joinOccurrences": int(row.get("join_occurrences") or 0),
        "filterOccurrences": int(row.get("filter_occurrences") or 0),
        "rowsProcessed": int(row.get("rows_processed") or 0),
        "rowsFiltered": int(row.get("rows_filtered") or 0),
        "filterRatio": None if ratio is None else round(float(ratio), 6),
        "sampleCount": int(row.get("sample_count") or 0),
        "observedFrom": row["observed_from"],
        "observedTo": row["observed_to"],
        "confidence": row["confidence"],
        "createIndexSql": row["create_index_sql"],
        "existingIndexChecked": bool(row.get("existing_index_checked")),
        "runtimeFixtureAvailable": bool(row.get("runtime_fixture_available")),
        "scoreIncluded": False,
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
        release = await repository.release_info()
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
        "release": _release_payload(release),
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


def _telemetry_capability(
    *,
    configured: bool,
    healthy: bool,
    data_available: bool,
    version: str | None,
    unavailable_reason: str,
) -> dict[str, Any]:
    if not configured:
        status_value = "NOT_CONFIGURED"
        reason_code = "NOT_CONFIGURED"
        reason = unavailable_reason
    elif not healthy:
        status_value = "DEGRADED"
        reason_code = "COLLECTOR_DEGRADED"
        reason = "Kaynak collector telemetrisi saglikli degil."
    elif not data_available:
        status_value = "WAITING_FOR_DATA"
        reason_code = "WAITING_FOR_DATA"
        reason = "Yapilandirma hazir; secili pencere icin veri bekleniyor."
    else:
        status_value = "AVAILABLE"
        reason_code = None
        reason = None
    return {
        "status": status_value,
        "configured": configured,
        "healthy": healthy if configured else None,
        "dataAvailable": data_available if configured else False,
        "available": status_value == "AVAILABLE",
        "version": version,
        "reasonCode": reason_code,
        "reason": reason,
    }


def _service_capability(
    *,
    configured: bool,
    target_matches: bool,
    health: dict[str, Any] | None,
    version: str | None = None,
) -> dict[str, Any]:
    if not configured or not target_matches:
        status_value = "NOT_CONFIGURED"
        reason_code = "TARGET_NOT_CONFIGURED"
        reason = "Bu kaynak ve veritabani icin evaluator yapilandirilmamis."
        healthy: bool | None = None
    elif health is None:
        status_value = "UNREACHABLE"
        reason_code = "EVALUATOR_UNREACHABLE"
        reason = "Evaluator saglik bilgisi alinamadi."
        healthy = False
    else:
        status_value = "AVAILABLE"
        reason_code = None
        reason = None
        healthy = True
    return {
        "status": status_value,
        "configured": configured and target_matches,
        "healthy": healthy,
        "dataAvailable": None,
        "available": status_value == "AVAILABLE",
        "version": version,
        "reasonCode": reason_code,
        "reason": reason,
    }


@router.get("/capabilities")
async def capabilities(
    window: Window = "24h",
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    rows = await repository.capability_rows(
        window=window, server_id=server_id, database_id=database_id
    )
    service_health = await evaluator_health()
    evaluator = service_health.get("evaluator")
    clone = service_health.get("clone")
    evaluator_alias = (
        (evaluator.get("sourceAlias") if evaluator else None)
        or settings.evaluator_allowed_server_alias
    )
    evaluator_database = (
        ((evaluator.get("databaseName") or evaluator.get("database_name")) if evaluator else None)
        or settings.evaluator_allowed_database
    )
    clone_alias = (clone.get("sourceAlias") if clone else None) or settings.clone_source_alias
    clone_database = (
        (clone.get("sourceDatabaseName") if clone else None)
        or settings.clone_template_database
    )
    items: list[dict[str, Any]] = []
    for row in rows:
        collector_healthy = row.get("collector_status") in {"HEALTHY", "STARTING"}
        evaluator_matches = (
            row.get("server_alias") == evaluator_alias
            and row.get("database_name") == evaluator_database
        )
        clone_matches = (
            row.get("server_alias") == clone_alias
            and row.get("database_name") == clone_database
        )
        join_configured = bool(row.get("join_configured"))
        join_status = str(row.get("join_status") or "UNAVAILABLE")
        join_healthy = join_status in {"HEALTHY", "STARTING"}
        capability_values = {
            "historicalMetrics": _telemetry_capability(
                configured=True,
                healthy=collector_healthy,
                data_available=bool(row.get("historical_data_available")),
                version=None,
                unavailable_reason="Kaynak repository'de kayitli degil.",
            ),
            "cpuMetrics": _telemetry_capability(
                configured=bool(row.get("kcache_configured")),
                healthy=collector_healthy,
                data_available=bool(row.get("cpu_data_available")),
                version=row.get("kcache_version"),
                unavailable_reason="pg_stat_kcache bu kaynakta yapilandirilmamis.",
            ),
            "waitSampling": _telemetry_capability(
                configured=bool(row.get("wait_configured")),
                healthy=collector_healthy,
                data_available=bool(row.get("wait_data_available")),
                version=row.get("wait_version"),
                unavailable_reason="pg_wait_sampling bu kaynakta yapilandirilmamis.",
            ),
            "predicateMetrics": _telemetry_capability(
                configured=bool(row.get("predicate_configured")),
                healthy=collector_healthy,
                data_available=bool(row.get("predicate_data_available")),
                version=row.get("predicate_version"),
                unavailable_reason="pg_qualstats bu kaynakta yapilandirilmamis.",
            ),
            "joinSnapshot": _telemetry_capability(
                configured=join_configured,
                healthy=join_healthy,
                data_available=bool(row.get("join_data_available")),
                version=None,
                unavailable_reason=str(row.get("join_reason") or "JOIN snapshotter yapilandirilmamis."),
            ),
            "hypopg": _service_capability(
                configured=bool(settings.evaluator_url),
                target_matches=evaluator_matches,
                health=evaluator,
                version=(
                    str(evaluator.get("hypopg_version"))
                    if evaluator and evaluator.get("hypopg_version")
                    else None
                ),
            ),
            "sourceExplain": _service_capability(
                configured=bool(settings.evaluator_url),
                target_matches=evaluator_matches,
                health=evaluator,
            ),
            "cloneValidation": _service_capability(
                configured=bool(settings.clone_evaluator_url),
                target_matches=clone_matches,
                health=clone,
            ),
        }
        capability_labels = {
            "historicalMetrics": "Historical metrics",
            "cpuMetrics": "CPU metrics",
            "waitSampling": "Wait sampling",
            "predicateMetrics": "Predicate metrics",
            "joinSnapshot": "JOIN snapshot",
            "hypopg": "HypoPG",
            "sourceExplain": "Source EXPLAIN",
            "cloneValidation": "Clone validation",
        }
        items.append({
            "serverId": int(row["server_id"]),
            "serverAlias": row.get("server_alias"),
            "databaseId": int(row["database_id"]),
            "databaseName": row.get("database_name"),
            "capabilities": [
                {"key": key, "label": capability_labels[key], **value}
                for key, value in capability_values.items()
            ],
        })
    return {"window": window, "scope": scope, "items": items}


@router.get("/database-optimize")
async def database_optimize(
    window: Window = "24h",
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=1, le=200, alias="pageSize"),
    sort_by: Literal["affectedLoad", "affectedQueries", "evidence"] = Query(
        default="affectedLoad", alias="sort"
    ),
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    rows, total, summary = await repository.database_optimize_rows(
        window=window,
        server_id=server_id,
        database_id=database_id,
        page=page,
        page_size=page_size,
        sort_by=sort_by,
    )
    return {
        "window": window,
        "scope": scope,
        "page": page,
        "pageSize": page_size,
        "total": total,
        "summary": {
            "candidateGroups": int(summary.get("candidate_groups") or 0),
            "validatedGroups": 0,
            "affectedQueries": int(summary.get("affected_queries") or 0),
            "affectedLoadMs": round(float(summary.get("affected_load_ms") or 0), 2),
        },
        "items": [
            {
                "groupId": row["group_id"],
                "serverId": row["server_id"],
                "serverAlias": row.get("server_alias"),
                "databaseId": row["database_id"],
                "databaseName": row.get("database_name"),
                "relationId": row["relation_id"],
                "schemaName": row["schema_name"],
                "tableName": row["table_name"],
                "method": row["method"],
                "columns": row["columns"],
                "orderingRules": row["ordering_rules"],
                "confidence": row["confidence"],
                "affectedQueryCount": row["affected_query_count"],
                "affectedQueryIds": [str(value) for value in row["affected_query_ids"]],
                "affectedLoadMs": round(float(row["affected_load_ms"]), 2),
                "evidence": {
                    "joinOccurrences": row["join_occurrences"],
                    "filterOccurrences": row["filter_occurrences"],
                    "sampleCount": row["sample_count"],
                    "observedFrom": row["observed_from"],
                    "observedTo": row["observed_to"],
                },
                "representative": {
                    "queryId": str(row["representative_query_id"]),
                    "candidateId": row["representative_candidate_id"],
                },
                "createIndexSql": row["create_index_sql"],
                "existingIndex": {
                    "status": "NOT_CHECKED",
                    "indexName": None,
                    "reason": "Mevcut index ortusmesi kaynak evaluator ile henuz kontrol edilmedi.",
                },
                "hypopg": {
                    "status": "NOT_EVALUATED",
                    "evaluatedQueries": 0,
                    "totalQueries": row["affected_query_count"],
                    "reason": "Bu toplu gorunum otomatik HypoPG sorgusu baslatmaz.",
                },
                "maintenanceCost": {
                    "writeRows": row["write_rows"],
                    "writesPerHour": row["writes_per_hour"],
                    "risk": row["maintenance_risk"],
                    "estimatedIndexSizeBytes": None,
                    "walBytesEstimate": None,
                    "reason": (
                        "Iliski yazma hacmi risk sinyalidir; onerilen indexin ek WAL byte miktari "
                        "mevcut telemetriden guvenilir bicimde hesaplanamaz."
                    ),
                },
            }
            for row in rows
        ],
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
    await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
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


@router.post(
    "/queries/{query_id}/explain-analyze",
    response_model=QueryExplainAnalyzeResult,
)
async def explain_query_runtime(
    query_id: int,
    payload: QueryExplainAnalyzeRequest,
    window: Window = "24h",
) -> dict[str, object]:
    """Run one persisted read-only query against the configured source DB.

    This loopback, single-user endpoint intentionally has no admin dependency.
    Its body cannot carry SQL: query identity and scope are resolved against
    repository telemetry before the internal token-protected source call.
    """
    query = await repository.query_by_id(
        query_id=query_id,
        window=window,
        server_id=payload.serverId,
        database_id=payload.databaseId,
    )
    if query is None:
        raise HTTPException(status_code=404, detail="Sorgu secili pencerede bulunamadi.")

    source_request = InternalQueryExplainAnalyzeRequest(
        serverId=payload.serverId,
        serverAlias=str(query.get("server_alias") or f"server-{payload.serverId}"),
        databaseId=payload.databaseId,
        databaseName=str(query.get("database_name") or f"db-{payload.databaseId}"),
        queryId=str(query_id),
        normalizedSql=str(query["sql_text"]),
        bindValues=payload.bindValues,
    )
    return await explain_query_on_source(source_request)


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
    join_rows, raw_join_capability = await repository.join_evidence(
        window=window,
        server_id=server_id,
        database_id=database_id,
        query_id=query_id,
    )
    candidate_rows = await repository.composite_candidates(
        window=window,
        server_id=server_id,
        database_id=database_id,
        query_id=query_id,
    )
    if candidate_rows:
        query = await repository.query_by_id(
            query_id=query_id,
            window=window,
            server_id=server_id,
            database_id=database_id,
        )
        fixture_candidates = (
            set()
            if query is None
            else await repository.runtime_replay_fixture_status(
                candidate_ids=[str(row["candidate_id"]) for row in candidate_rows],
                server_id=server_id,
                database_id=database_id,
                query_id=query_id,
                normalized_sql=str(query["sql_text"]),
            )
        )
        for candidate_row in candidate_rows:
            candidate_row["runtime_fixture_available"] = (
                str(candidate_row["candidate_id"]) in fixture_candidates
            )
    available = bool(raw_capability.get("available"))
    joins_available = bool(raw_join_capability.get("available"))
    observed_from = min((row["observed_from"] for row in rows), default=None)
    observed_to = max((row["observed_to"] for row in rows), default=None)
    if not available:
        reason = "pg_qualstats bu kaynakta etkin degil; predicate/index adayi verisi uretilemiyor."
    elif not rows:
        reason = "pg_qualstats etkin, ancak secili pencerede bu sorgu icin predicate ornegi yok."
    elif joins_available:
        reason = (
            "WHERE filtreleri PoWA pg_qualstats gecmisinden, JOIN iliskileri ise "
            "pg_qualstats reset sinirinda atomik outbox snapshot'larindan gelir. "
            "Occurrence degeri statement cagri sayisi degildir."
        )
    else:
        reason = (
            "PoWA 5.2 repository hatti WHERE/filter predicate gecmisini tasir; JOIN "
            "snapshotter yapilandirilmadigi icin JOIN yoklugu sorguda JOIN olmadigi "
            "anlamina gelmez. Occurrence degeri statement cagri sayisi degildir."
        )
    return {
        "window": window,
        "queryId": str(query_id),
        "capability": {
            "available": available,
            "version": raw_capability.get("version"),
            "dataAvailable": bool(rows or join_rows),
            "coverage": "WHERE_AND_JOIN_SNAPSHOT" if joins_available else "WHERE_FILTER_ONLY",
            "joinsAvailable": joins_available,
            "ddlGenerated": bool(candidate_rows),
            "reason": reason,
            "observedFrom": observed_from,
            "observedTo": observed_to,
        },
        "items": [_predicate_payload(row) for row in rows],
        "joinCapability": {
            "available": joins_available,
            "dataAvailable": bool(raw_join_capability.get("data_available")),
            "status": raw_join_capability.get("status") or "UNAVAILABLE",
            "lastSnapshotAt": raw_join_capability.get("last_snapshot_at"),
            "lagSeconds": raw_join_capability.get("lag_seconds"),
            "captureMode": raw_join_capability.get("capture_mode") or "QUALSTATS_RESET_BOUNDARY",
            "reason": raw_join_capability.get("reason")
            or "JOIN snapshotter bu kaynak icin yapilandirilmamis.",
        },
        "joins": [_join_payload(row) for row in join_rows],
        "candidates": [_candidate_payload(row) for row in candidate_rows],
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


@router.post("/queries/{query_id}/composite-index-evaluations", response_model=IndexAdvice)
async def evaluate_composite_query_index(
    query_id: int,
    payload: CompositeIndexEvaluationRequest,
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
) -> dict[str, Any]:
    if not can_view_sql(role):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Composite HypoPG plan dogrulamasi analyst yetkisi gerektirir.",
        )

    candidate = await repository.composite_candidate(
        candidate_id=payload.candidateId,
        server_id=payload.serverId,
        database_id=payload.databaseId,
        query_id=query_id,
        window=window,
    )
    if candidate is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Composite index adayi secili pencerede bulunamadi.",
        )
    columns = list(candidate.get("key_column_names") or [])
    operator_oids = [int(value) for value in (candidate.get("operator_oids") or [])]
    if len(columns) != 2 or not operator_oids or candidate.get("schema_name") == "unknown":
        return {
            "status": "UNSAFE",
            "reasonCode": "UNRESOLVED_COMPOSITE_CANDIDATE",
            "message": "Composite aday katalog kimlikleri guvenle cozumlenemedi.",
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
        serverAlias=str(query.get("server_alias") or f"server-{payload.serverId}"),
        databaseId=payload.databaseId,
        databaseName=str(query.get("database_name") or f"db-{payload.databaseId}"),
        queryId=str(query_id),
        normalizedSql=str(query["sql_text"]),
        qualId="0",
        relationId=int(candidate["relation_id"]),
        schemaName=str(candidate["schema_name"]),
        tableName=str(candidate["table_name"]),
        columns=columns,
        operatorOids=operator_oids,
        occurrences=int(candidate.get("join_occurrences") or 0)
        + int(candidate.get("filter_occurrences") or 0),
        rowsProcessed=int(candidate.get("rows_processed") or 0),
        filterRatio=(
            None
            if candidate.get("filter_ratio") is None
            else float(candidate["filter_ratio"])
        ),
        sampleCount=int(candidate.get("sample_count") or 0),
    )
    return await evaluate_index_candidate(request)


@router.post(
    "/queries/{query_id}/runtime-index-validations",
    response_model=CloneIndexEvaluationResult,
)
async def validate_query_index_runtime(
    query_id: int,
    payload: RuntimeIndexValidationRequest,
    principal: Annotated[RequestPrincipal, Depends(request_admin_principal)],
    window: Window = "24h",
) -> dict[str, Any]:
    candidate = await repository.composite_candidate(
        candidate_id=payload.candidateId,
        server_id=payload.serverId,
        database_id=payload.databaseId,
        query_id=query_id,
        window=window,
    )
    if candidate is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Runtime dogrulama icin persisted composite aday bulunamadi.",
        )
    query = await repository.query_by_id(
        query_id=query_id,
        window=window,
        server_id=payload.serverId,
        database_id=payload.databaseId,
    )
    if query is None:
        raise HTTPException(status_code=404, detail="Sorgu secili pencerede bulunamadi.")

    fixture = await repository.runtime_replay_fixture(
        candidate_id=payload.candidateId,
        server_id=payload.serverId,
        database_id=payload.databaseId,
        query_id=query_id,
        normalized_sql=str(query["sql_text"]),
    )
    if fixture is None:
        return {
            "status": "UNAVAILABLE",
            "reasonCode": "REPLAY_FIXTURE_REQUIRED",
            "message": (
                "Bu normalize sorgu ve persisted aday icin operator onayli sentetik "
                "replay fixture yok; clone'da EXPLAIN ANALYZE baslatilmadi."
            ),
            "candidateId": payload.candidateId,
            "validation": None,
            "ddlTarget": "DISPOSABLE_CLONE",
            "sourceDdlExecuted": False,
            "cloneDdlExecuted": False,
            "cloneDestroyed": True,
        }

    columns = list(candidate.get("key_column_names") or [])
    operator_oids = [int(value) for value in (candidate.get("operator_oids") or [])]
    planner_request = InternalIndexEvaluationRequest(
        serverId=payload.serverId,
        serverAlias=str(query.get("server_alias") or f"server-{payload.serverId}"),
        databaseId=payload.databaseId,
        databaseName=str(query.get("database_name") or f"db-{payload.databaseId}"),
        queryId=str(query_id),
        normalizedSql=str(query["sql_text"]),
        qualId="0",
        relationId=int(candidate["relation_id"]),
        schemaName=str(candidate["schema_name"]),
        tableName=str(candidate["table_name"]),
        columns=columns,
        operatorOids=operator_oids,
        occurrences=int(candidate.get("join_occurrences") or 0)
        + int(candidate.get("filter_occurrences") or 0),
        rowsProcessed=int(candidate.get("rows_processed") or 0),
        filterRatio=(
            None
            if candidate.get("filter_ratio") is None
            else float(candidate["filter_ratio"])
        ),
        sampleCount=int(candidate.get("sample_count") or 0),
    )
    planner_result = await evaluate_index_candidate(planner_request)
    if planner_result.get("status") != "VALIDATED":
        return {
            "status": "UNAVAILABLE",
            "reasonCode": "PLANNER_VALIDATION_REQUIRED",
            "message": (
                "Gercek clone testi oncesinde ayni persisted aday HypoPG tarafindan "
                "dogrulanmali: " + str(planner_result.get("message") or "planner dogrulamadi")
            ),
            "candidateId": payload.candidateId,
            "validation": None,
            "ddlTarget": "DISPOSABLE_CLONE",
            "sourceDdlExecuted": False,
            "cloneDdlExecuted": False,
            "cloneDestroyed": True,
        }

    index_name = _proposed_index_name(
        planner_request.schemaName,
        planner_request.tableName,
        planner_request.columns,
    )
    clone_candidate = ValidatedCloneIndexCandidate(
        candidateId=payload.candidateId,
        plannerValidation="VALIDATED",
        method="btree",
        schemaName=planner_request.schemaName,
        tableName=planner_request.tableName,
        columns=planner_request.columns,
        indexName=index_name,
        createIndexSql="placeholder",
    )
    clone_candidate = clone_candidate.model_copy(
        update={"createIndexSql": _production_index_sql(clone_candidate)}
    )
    clone_request = InternalCloneIndexEvaluationRequest(
        serverAlias=planner_request.serverAlias,
        databaseName=planner_request.databaseName,
        queryId=planner_request.queryId,
        normalizedSql=planner_request.normalizedSql,
        bindValues=list(fixture["bind_values"]),
        candidate=clone_candidate,
    )
    return await validate_index_on_clone(clone_request)


@router.patch("/queries/{query_id}/annotation")
async def update_annotation(
    query_id: int,
    payload: AnnotationUpdate,
    principal: Annotated[RequestPrincipal, Depends(request_annotator_principal)],
    server_id: int = Query(alias="serverId"),
    database_id: int = Query(alias="databaseId"),
) -> dict[str, Any]:
    row = await repository.annotate(
        server_id=server_id,
        database_id=database_id,
        query_id=query_id,
        status=payload.status,
        note=payload.note,
        actor=principal.subject,
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
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    rows, total = await repository.query_rows(
        window=window,
        page=page,
        page_size=page_size,
        sort_by="regression",
        regressions_only=True,
        server_id=server_id,
        database_id=database_id,
    )
    return {
        "items": [serialize_query(row, sql_visible=can_view_sql(role)) for row in rows],
        "page": page,
        "pageSize": page_size,
        "total": total,
        "window": window,
        "scope": scope,
    }


@router.get("/overview")
async def overview(
    role: Annotated[str, Depends(request_role)],
    window: Window = "24h",
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    row_args: dict[str, Any] = {"window": window, "page_size": 10, "sort_by": "impact"}
    summary_args: dict[str, Any] = {"window": window}
    trend_args: dict[str, Any] = {"window": window}
    if server_id is not None:
        row_args.update(server_id=server_id, database_id=database_id)
        summary_args.update(server_id=server_id, database_id=database_id)
        trend_args.update(server_id=server_id, database_id=database_id)
    rows, _ = await repository.query_rows(**row_args)
    summary = await repository.overview_summary(**summary_args)
    collectors = await repository.collector_health(server_id) if server_id is not None else await repository.collector_health()
    collector_summary = _summarize_collectors(collectors)
    trend = await repository.trend(**trend_args)
    return {
        "window": window,
        "scope": scope,
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
    await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
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
    await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
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
async def system_health(
    window: Window = "24h",
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    rows = await repository.table_health(server_id=server_id, database_id=database_id)
    summary = await repository.table_health_summary(server_id=server_id, database_id=database_id)
    transactions = await repository.long_transactions(server_id=server_id, database_id=database_id)
    items = [_table_payload(row) for row in rows]
    return {
        "window": window,
        "summary": {
            "tablesObserved": int(summary.get("tables_observed") or 0),
            "critical": int(summary.get("critical") or 0),
            "warnings": int(summary.get("warnings") or 0),
            "notices": int(summary.get("notices") or 0),
        },
        "scope": scope,
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
async def operations(
    window: Window = "24h",
    server_id: Annotated[int | None, Query(alias="serverId")] = None,
    database_id: Annotated[int | None, Query(alias="databaseId")] = None,
) -> dict[str, Any]:
    scope = await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    database = await repository.ping()
    release = await repository.release_info()
    collectors = await repository.collector_health(server_id) if server_id is not None else await repository.collector_health()
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
        "window": window,
        "scope": scope,
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
        "release": _release_payload(release),
    }


@router.get("/export/queries.csv")
async def export_queries(
    principal: Annotated[RequestPrincipal, Depends(request_admin_principal)],
    window: Window = "24h",
    search: str | None = Query(default=None, max_length=300),
    priority: str | None = None,
    server_id: int | None = Query(default=None, alias="serverId"),
    database_id: int | None = Query(default=None, alias="databaseId"),
    min_calls: int = Query(default=0, ge=0, alias="minCalls"),
    min_duration_ms: float = Query(default=0, ge=0, alias="minDurationMs"),
    sort_by: str = Query(default="impact", alias="sort"),
) -> StreamingResponse:
    await _scope_payload(
        window=window, server_id=server_id, database_id=database_id
    )
    export_id = str(uuid4())
    export_context = {
        "exportId": export_id,
        "credentialId": principal.credential_id,
        "window": window,
        "filters": {
            "search": search,
            "priority": priority,
            "serverId": server_id,
            "databaseId": database_id,
            "minCalls": min_calls,
            "minDurationMs": min_duration_ms,
            "sort": sort_by,
        },
    }
    await repository.record_query_export_audit(
        actor=principal.subject,
        phase="REQUESTED",
        details=export_context,
    )

    async def body():
        row_count = 0
        async with aclosing(
            repository.stream_query_rows(
                window=window,
                search=search,
                priority=priority,
                server_id=server_id,
                database_id=database_id,
                min_calls=min_calls,
                min_duration_ms=min_duration_ms,
                sort_by=sort_by,
            )
        ) as batches:
            yield _query_csv_chunk([], include_header=True)
            async for rows in batches:
                row_count += len(rows)
                yield _query_csv_chunk(rows)

        # The cursor connection has returned to the pool before completion
        # audit takes a second connection.  This ordering avoids pool
        # starvation under concurrent exports.  A disconnected client keeps
        # the durable REQUESTED entry but does not receive a false completion.
        await repository.record_query_export_audit(
            actor=principal.subject,
            phase="COMPLETED",
            details={**export_context, "rows": row_count},
        )

    return StreamingResponse(
        content=body(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="queries-{window}.csv"'},
    )
