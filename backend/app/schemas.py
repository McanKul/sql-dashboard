from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator


ALLOWED_STATUSES = {"NEW", "IN_REVIEW", "COMPLETED", "REJECTED"}


class AnnotationUpdate(BaseModel):
    status: str
    note: str | None = Field(default=None, max_length=4000)
    updated_by: str = Field(alias="updatedBy", min_length=1, max_length=120)

    @field_validator("status")
    @classmethod
    def validate_status(cls, value: str) -> str:
        normalized = value.upper()
        if normalized not in ALLOWED_STATUSES:
            raise ValueError(f"status sunlardan biri olmali: {', '.join(sorted(ALLOWED_STATUSES))}")
        return normalized


class QueryFilters(BaseModel):
    window: str = "24h"
    page: int = Field(default=1, ge=1)
    page_size: int = Field(default=50, ge=1, le=200)


class IndexSummary(BaseModel):
    indexesObserved: int
    candidateSignals: int
    totalSizeBytes: int
    noScanSizeBytes: int


class IndexItem(BaseModel):
    serverId: int
    serverAlias: str
    databaseId: int
    databaseName: str | None
    relationId: int
    tableName: str | None
    indexId: int
    indexName: str | None
    sizeBytes: int
    scans: int
    tuplesRead: int
    tuplesFetched: int
    blocksRead: int
    blocksHit: int
    cacheHitPercent: float | None
    lastScanAt: datetime | None
    signalLevel: Literal["WARNING", "NOTICE", "HEALTHY", "UNKNOWN"]
    signal: Literal["NO_SCANS_OBSERVED", "LOW_USAGE_OBSERVED", "INSUFFICIENT_DATA", "HEALTHY"]
    recommendation: str


class IndexResponse(BaseModel):
    window: Literal["1h", "24h", "7d", "30d"]
    summary: IndexSummary
    items: list[IndexItem]


class IoSummary(BaseModel):
    reads: int
    writes: int
    readBytes: int
    writeBytes: int
    extendBytes: int
    cacheHits: int
    cacheHitPercent: float | None
    tempBytes: int
    walBytes: int
    checkpoints: int
    checkpointWriteTimeMs: float
    backendWrites: int


class DatabaseIoItem(BaseModel):
    serverId: int
    serverAlias: str
    databaseId: int
    databaseName: str | None
    currentBackends: int
    transactionsCommitted: int
    transactionsRolledBack: int
    blocksRead: int
    blocksHit: int
    cacheHitPercent: float | None
    tempFiles: int
    tempBytes: int
    deadlocks: int
    blockReadTimeMs: float
    blockWriteTimeMs: float
    tuplesReturned: int
    tuplesFetched: int
    tuplesInserted: int
    tuplesUpdated: int
    tuplesDeleted: int


class IoContextItem(BaseModel):
    serverId: int
    serverAlias: str
    backendType: str | None
    object: str | None
    context: str | None
    reads: int
    readBytes: int
    readTimeMs: float
    writes: int
    writeBytes: int
    writeTimeMs: float
    writebacks: int
    writebackTimeMs: float
    extends: int
    extendBytes: int
    extendTimeMs: float
    hits: int
    evictions: int
    reuses: int
    fsyncs: int
    fsyncTimeMs: float


class ServerOperationItem(BaseModel):
    serverId: int
    serverAlias: str
    walRecords: int
    walFpi: int
    walBytes: int
    walBuffersFull: int
    walWrites: int
    walSyncs: int
    walWriteTimeMs: float
    walSyncTimeMs: float
    timedCheckpoints: int
    requestedCheckpoints: int
    checkpointWriteTimeMs: float
    checkpointSyncTimeMs: float
    checkpointBuffersWritten: int
    buffersClean: int
    maxwrittenClean: int
    buffersBackend: int
    buffersBackendFsync: int
    buffersAllocated: int


class TelemetryCapability(BaseModel):
    key: str
    available: bool
    resetEpochAware: bool
    source: str
    limitation: str | None = None


class IoResponse(BaseModel):
    window: Literal["1h", "24h", "7d", "30d"]
    summary: IoSummary
    capabilities: list[TelemetryCapability]
    databases: list[DatabaseIoItem]
    contexts: list[IoContextItem]
    servers: list[ServerOperationItem]

