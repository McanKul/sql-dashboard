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


class PredicateCapability(BaseModel):
    available: bool
    version: str | None = None
    dataAvailable: bool
    coverage: Literal["WHERE_FILTER_ONLY", "WHERE_AND_JOIN_SNAPSHOT"]
    joinsAvailable: bool
    ddlGenerated: bool
    reason: str
    observedFrom: datetime | None = None
    observedTo: datetime | None = None


class PredicateEvidence(BaseModel):
    serverId: int
    serverAlias: str
    databaseId: int
    databaseName: str
    queryId: str
    qualId: str
    relationId: int
    schemaName: str
    tableName: str
    columns: list[str]
    operatorOids: list[int]
    evalType: Literal["FILTER", "INDEX_CONDITION", "UNKNOWN"]
    occurrences: int
    rowsProcessed: int
    rowsFiltered: int
    filterRatio: float | None
    observedFrom: datetime
    observedTo: datetime
    sampleCount: int
    signal: Literal[
        "INDEX_CANDIDATE",
        "REVIEW",
        "INDEX_CONDITION_OBSERVED",
        "OBSERVED",
        "INSUFFICIENT_DATA",
    ]
    recommendation: str


class PredicateResponse(BaseModel):
    window: Literal["1h", "24h", "7d", "30d"]
    queryId: str
    capability: PredicateCapability
    items: list[PredicateEvidence]
    joinCapability: JoinSnapshotCapability
    joins: list[JoinPredicateEvidence]
    candidates: list[CompositeIndexCandidate]


class JoinSnapshotCapability(BaseModel):
    available: bool
    dataAvailable: bool
    status: Literal["STARTING", "HEALTHY", "DEGRADED", "ERROR", "UNAVAILABLE"]
    lastSnapshotAt: datetime | None = None
    lagSeconds: float | None = None
    captureMode: Literal["QUALSTATS_RESET_BOUNDARY"]
    reason: str


class JoinPredicateEvidence(BaseModel):
    serverId: int
    serverAlias: str
    databaseId: int
    databaseName: str
    queryId: str
    qualId: str
    qualNodeId: str
    leftRelationId: int
    leftSchemaName: str
    leftTableName: str
    leftColumnName: str
    rightRelationId: int
    rightSchemaName: str
    rightTableName: str
    rightColumnName: str
    operatorOid: int
    operatorName: str | None = None
    btreeStrategy: int | None = None
    occurrences: int
    rowsProcessed: int
    sampleCount: int
    observedFrom: datetime
    observedTo: datetime
    signal: Literal["FREQUENT_JOIN", "OBSERVED_JOIN", "INSUFFICIENT_DATA"]
    scoreIncluded: Literal[False]


class CompositeIndexCandidate(BaseModel):
    candidateId: str
    serverId: int
    databaseId: int
    queryId: str
    relationId: int
    schemaName: str
    tableName: str
    method: Literal["btree"]
    columns: list[str] = Field(min_length=2, max_length=2)
    operatorOids: list[int]
    orderingRule: Literal[
        "SELECTIVE_EQUALITY_FILTER_THEN_JOIN",
        "EQUALITY_JOIN_THEN_FILTER",
        "EQUALITY_JOIN_THEN_RANGE_FILTER",
    ]
    joinOccurrences: int
    filterOccurrences: int
    rowsProcessed: int
    rowsFiltered: int
    filterRatio: float | None = None
    sampleCount: int
    observedFrom: datetime
    observedTo: datetime
    confidence: Literal["LOW", "MEDIUM", "HIGH"]
    createIndexSql: str
    existingIndexChecked: bool
    runtimeFixtureAvailable: bool
    scoreIncluded: Literal[False]


class IndexEvaluationRequest(BaseModel):
    serverId: int = Field(ge=1)
    databaseId: int = Field(ge=1)
    qualId: str = Field(min_length=1, max_length=32, pattern=r"^-?\d+$")
    relationId: int = Field(ge=1)


class CompositeIndexEvaluationRequest(BaseModel):
    serverId: int = Field(ge=1)
    databaseId: int = Field(ge=1)
    candidateId: str = Field(
        min_length=36,
        max_length=36,
        pattern=r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )


class RuntimeIndexValidationRequest(CompositeIndexEvaluationRequest):
    pass


class IndexCandidateSql(BaseModel):
    method: Literal["btree"]
    columns: list[str]
    createIndexSql: str
    copyable: Literal[True]


class IndexPlanValidation(BaseModel):
    mode: Literal["GENERIC_PLAN", "PLAIN_PLAN"]
    hypopgVersion: str
    baselineTotalCost: float
    hypotheticalTotalCost: float
    costReductionPercent: float
    hypotheticalIndexUsed: bool
    baselineAccess: str | None = None
    hypotheticalAccess: str | None = None
    estimatedIndexSizeBytes: int
    tableSizeBytes: int
    evaluatedAt: datetime


class IndexAdviceConfidence(BaseModel):
    level: Literal["MEDIUM", "HIGH"]
    reasons: list[str]


class IndexAdvice(BaseModel):
    status: Literal["VALIDATED", "NO_IMPROVEMENT", "UNAVAILABLE", "UNSAFE", "INSUFFICIENT"]
    reasonCode: str
    message: str
    candidate: IndexCandidateSql | None = None
    validation: IndexPlanValidation | None = None
    confidence: IndexAdviceConfidence | None = None
    ddlExecuted: Literal[False]


class InternalIndexEvaluationRequest(BaseModel):
    serverId: int = Field(ge=1)
    serverAlias: str = Field(min_length=1, max_length=120)
    databaseId: int = Field(ge=1)
    databaseName: str = Field(min_length=1, max_length=128)
    queryId: str = Field(min_length=1, max_length=32, pattern=r"^-?\d+$")
    normalizedSql: str = Field(min_length=1, max_length=100_000)
    qualId: str = Field(min_length=1, max_length=32, pattern=r"^-?\d+$")
    relationId: int = Field(ge=1)
    schemaName: str = Field(min_length=1, max_length=128)
    tableName: str = Field(min_length=1, max_length=128)
    columns: list[str] = Field(min_length=1, max_length=2)
    operatorOids: list[int] = Field(min_length=1, max_length=8)
    occurrences: int = Field(ge=0)
    rowsProcessed: int = Field(ge=0)
    filterRatio: float | None = Field(default=None, ge=0, le=1)
    sampleCount: int = Field(ge=0)

    @field_validator("columns")
    @classmethod
    def validate_distinct_columns(cls, value: list[str]) -> list[str]:
        if any(not column or len(column) > 128 for column in value):
            raise ValueError("column names must be 1-128 characters")
        if len(set(value)) != len(value):
            raise ValueError("index columns must be distinct")
        return value


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
