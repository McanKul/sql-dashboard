from __future__ import annotations

from datetime import datetime
import json
import math
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


ALLOWED_STATUSES = {"NEW", "IN_REVIEW", "COMPLETED", "REJECTED"}
SOURCE_EXPLAIN_MAX_BIND_VALUES = 128
SOURCE_EXPLAIN_MAX_BIND_BYTES = 64 * 1024


class AnnotationUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: str
    note: str | None = Field(default=None, max_length=4000)

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


class QueryExplainAnalyzeRequest(BaseModel):
    """Caller-controlled scope and bind values for source query replay.

    SQL is deliberately absent from this public contract.  The API resolves
    the statement text from its persisted query telemetry before contacting
    the token-protected, read-only source evaluator.
    """

    model_config = ConfigDict(extra="forbid")

    serverId: int = Field(ge=1, strict=True)
    databaseId: int = Field(ge=1, strict=True)
    bindValues: list[str | int | float | bool | None] = Field(
        default_factory=list,
        max_length=SOURCE_EXPLAIN_MAX_BIND_VALUES,
    )

    @field_validator("bindValues", mode="before")
    @classmethod
    def bind_values_are_bounded_json_scalars(
        cls,
        values: object,
    ) -> object:
        if not isinstance(values, list):
            raise ValueError("bindValues bir JSON listesi olmali")
        for value in values:
            if type(value) not in {str, int, float, bool, type(None)}:
                raise ValueError("bindValues yalnizca JSON scalar degerleri icerebilir")
            if isinstance(value, str) and len(value) > 2_048:
                raise ValueError("bindValues string degeri en fazla 2048 karakter olabilir")
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError("bindValues sonlu olmayan sayi iceremez")
        if len(
            json.dumps(
                values,
                ensure_ascii=False,
                allow_nan=False,
            ).encode("utf-8")
        ) > SOURCE_EXPLAIN_MAX_BIND_BYTES:
            raise ValueError("bindValues UTF-8 JSON boyutu en fazla 64 KiB olabilir")
        return values


class InternalQueryExplainAnalyzeRequest(BaseModel):
    """Server-resolved statement passed only to the source evaluator."""

    model_config = ConfigDict(extra="forbid")

    serverId: int = Field(ge=1, strict=True)
    serverAlias: str = Field(min_length=1, max_length=120)
    databaseId: int = Field(ge=1, strict=True)
    databaseName: str = Field(min_length=1, max_length=63)
    queryId: str = Field(min_length=1, max_length=32, pattern=r"^-?\d+$")
    normalizedSql: str = Field(min_length=1, max_length=100_000)
    bindValues: list[str | int | float | bool | None] = Field(
        default_factory=list,
        max_length=SOURCE_EXPLAIN_MAX_BIND_VALUES,
    )

    @field_validator("bindValues", mode="before")
    @classmethod
    def bind_values_are_bounded_json_scalars(
        cls,
        values: object,
    ) -> object:
        return QueryExplainAnalyzeRequest.bind_values_are_bounded_json_scalars(values)


class QueryExplainAnalyzeValidation(BaseModel):
    mode: Literal["EXPLAIN_ANALYZE"] = "EXPLAIN_ANALYZE"
    statementClass: Literal["READ_ONLY_SELECT"] = "READ_ONLY_SELECT"
    planPreflight: Literal["READ_ONLY"] = "READ_ONLY"
    transactionReadOnly: Literal[True] = True
    safetyPolicyRevision: int = Field(ge=1)
    postgresVersion: str = Field(min_length=1)
    executionRole: str = Field(min_length=1)
    databaseId: int = Field(ge=1)
    executionTimeMs: float = Field(ge=0)
    planningTimeMs: float = Field(ge=0)
    sharedHitBlocks: int = Field(ge=0)
    sharedReadBlocks: int = Field(ge=0)
    tempReadBlocks: int = Field(ge=0)
    tempWrittenBlocks: int = Field(ge=0)
    walRecords: int = Field(ge=0)
    walBytes: int = Field(ge=0)
    plan: dict[str, Any]
    evaluatedAt: datetime

    @field_validator("plan")
    @classmethod
    def plan_has_a_postgresql_node_tree(cls, value: dict[str, Any]) -> dict[str, Any]:
        root = value.get("Plan")
        if not isinstance(root, dict) or not isinstance(root.get("Node Type"), str):
            raise ValueError("plan must contain a PostgreSQL Plan node tree")
        return value


class QueryExplainAnalyzeResult(BaseModel):
    status: Literal["RUNTIME_VALIDATED", "UNAVAILABLE", "UNSAFE"]
    reasonCode: str
    message: str
    queryId: str
    validation: QueryExplainAnalyzeValidation | None = None
    executionTarget: Literal["SOURCE_DATABASE"] = "SOURCE_DATABASE"
    sourceExecuted: bool | None
    sourceDdlExecuted: Literal[False] = False
    transactionRolledBack: bool | None

    @model_validator(mode="after")
    def successful_result_is_measured_and_rolled_back(
        self,
    ) -> "QueryExplainAnalyzeResult":
        if self.status == "RUNTIME_VALIDATED" and (
            self.validation is None
            or not self.sourceExecuted
            or not self.transactionRolledBack
        ):
            raise ValueError(
                "RUNTIME_VALIDATED requires source execution, validation and rollback"
            )
        return self


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
