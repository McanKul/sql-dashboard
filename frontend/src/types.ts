export type PageId = 'overview' | 'queries' | 'health' | 'operations'

export type TimeWindow = '1h' | '24h' | '7d' | '30d'

export type Severity = 'critical' | 'warning' | 'healthy'

export interface TrendPoint {
  label: string
  value: number
}

export interface OverviewStats {
  databaseName: string
  environment: string
  lastCollectedAt: string
  queriesAnalyzed: number
  criticalQueries: number
  regressions: number
  databaseTimeHours: number
  latencyTrend: TrendPoint[]
  recentActivity: Array<{
    id: string
    title: string
    detail: string
    occurredAt: string
    tone: Severity
  }>
  opportunities: Array<{
    queryId: string
    title: string
    averageMs: number
    loadPercent: number
  }>
}

export interface QuerySummary {
  id: string
  queryId: string
  serverId: number
  serverAlias?: string
  databaseId: number
  fingerprint: string
  title: string
  sqlPreview: string
  database: string
  calls: number
  avgDurationMs: number
  totalTimeMs: number
  dbLoadPercent: number
  sharedBlocksHit: number
  sharedBlocksRead: number
  tempBlocksWritten: number
  walBytes: number
  impactScore: number
  priority: string
  severity: Severity
  lastSeenAt: string
  changePercent: number
  hasComparison: boolean
}

export interface ScoreBreakdown {
  key: string
  label: string
  contribution: number
  maxContribution: number
  hint: string
  percentileScore?: number
  volumeFactor?: number
  absoluteValue?: number
  fullScoreAt?: number
  unit?: string
}

export interface QueryFinding {
  id: string
  severity: Severity
  title: string
  description: string
  recommendation: string
}

export interface QueryDetail extends QuerySummary {
  fullSql: string
  firstSeenAt: string
  p95DurationMs?: number
  rowsPerCall?: number
  durationDistribution?: { available: boolean; reason?: string }
  trend: Array<{
    label: string
    durationMs: number
    impactScore: number
  }>
  scoreBreakdown: ScoreBreakdown[]
  comparison: Array<{
    metric: string
    before: number
    after: number
    unit: string
    improvementPercent: number
  }>
  findings: QueryFinding[]
}

export interface SystemHealth {
  collectedAt: string
  postgresVersion: string
  overall: Severity
  metrics: Array<{
    key: string
    label: string
    value: number
    unit: string
    target: string
    severity: Severity
    description: string
    history: TrendPoint[]
  }>
  databases: Array<{
    serverId: number
    databaseId: number
    name: string
    sizeGb: number
    tableCount: number
    sequentialScans: number
    indexScans: number
    deadTuples: number
    signals: number
    severity: Severity
  }>
  capabilities: Array<{
    key: string
    label: string
    available: boolean
    source: string
    reason?: string
  }>
}

export interface ApiList<T> {
  items: T[]
  total: number
  page?: number
  pageSize?: number
  window?: TimeWindow
}

export interface QueryListParams {
  page: number
  pageSize: number
  search?: string
  priority?: string
  serverId?: number
  databaseId?: number
  minCalls?: number
  minDurationMs?: number
  sort?: 'impact' | 'regression' | 'meanTime' | 'calls' | 'totalTime' | 'reads'
}

export interface ServerOption {
  id: number
  alias: string
  hostname?: string
  database?: string
}

export interface DatabaseOption {
  serverId: number
  databaseId: number
  name: string
}

export interface IndexTelemetryItem {
  serverId: number
  serverAlias?: string
  databaseId: number
  databaseName: string
  relationId?: number
  indexId?: number
  schemaName?: string
  tableName: string
  indexName: string
  indexSizeBytes: number
  indexScans: number
  tuplesRead?: number
  tuplesFetched?: number
  blocksRead?: number
  blocksHit?: number
  cacheHitPercent?: number | null
  tableWrites?: number
  lastUsedAt?: string | null
  signalLevel?: string
  signal?: string
  recommendation?: string | null
}

export interface IoTelemetryItem {
  serverId: number
  serverAlias?: string
  databaseId: number
  databaseName: string
  sampleAt?: string | null
  sharedBlocksHit: number
  sharedBlocksRead: number
  tempBlocksWritten: number
  tempBytes?: number
  walBytes: number
  readTimeMs?: number
  writeTimeMs?: number
  currentBackends?: number
  transactionsCommitted?: number
  transactionsRolledBack?: number
  tempFiles?: number
  deadlocks?: number
  tuplesReturned?: number
  tuplesFetched?: number
  tuplesInserted?: number
  tuplesUpdated?: number
  tuplesDeleted?: number
}

export interface IoTelemetryCapability {
  key: string
  available: boolean
  resetEpochAware: boolean
  source: string
  limitation?: string | null
}

export interface IoContextTelemetryItem {
  serverId: number
  serverAlias?: string
  backendType?: string | null
  object?: string | null
  context?: string | null
  reads: number
  readBytes: number
  readTimeMs: number
  writes: number
  writeBytes: number
  writeTimeMs: number
  writebacks: number
  writebackTimeMs: number
  extends: number
  extendBytes: number
  extendTimeMs: number
  hits: number
  evictions: number
  reuses: number
  fsyncs: number
  fsyncTimeMs: number
}

export interface ServerOperationTelemetryItem {
  serverId: number
  serverAlias?: string
  walRecords: number
  walFpi: number
  walBytes: number
  walBuffersFull: number
  walWrites: number
  walSyncs: number
  walWriteTimeMs: number
  walSyncTimeMs: number
  timedCheckpoints: number
  requestedCheckpoints: number
  checkpointWriteTimeMs: number
  checkpointSyncTimeMs: number
  checkpointBuffersWritten: number
  buffersClean: number
  maxwrittenClean: number
  buffersBackend: number
  buffersBackendFsync: number
  buffersAllocated: number
}

export interface OperationsData {
  architecture: {
    host?: string
    dataFlow: string[]
    apiSourceConnection?: boolean
    sourceCount: number
  }
  services: Array<{ name: string; service: string; status: string }>
  collector: {
    alias?: string
    hostname?: string
    port?: number | null
    frequencySeconds?: number | null
    retention?: string | null
    lastSnapshotAt?: string | null
    lagSeconds?: number | null
    status?: string
    errors: string[]
  }
  collectors: Array<{
    serverId?: number
    alias?: string
    hostname?: string
    port?: number | null
    frequencySeconds?: number | null
    retention?: string | null
    lastSnapshotAt?: string | null
    lagSeconds?: number | null
    status?: string
    errors: string[]
  }>
  repository: {
    postgresVersion?: string
    powaVersion?: string
    sizeBytes: number
    retentionDays: number
  }
  indexes: {
    available: boolean
    message?: string
    summary?: {
      indexesObserved: number
      candidateSignals: number
      totalSizeBytes: number
      noScanSizeBytes: number
    }
    items: IndexTelemetryItem[]
  }
  io: {
    available: boolean
    message?: string
    summary?: {
      reads: number
      writes: number
      readBytes: number
      writeBytes: number
      extendBytes: number
      cacheHits: number
      cacheHitPercent?: number | null
      tempBytes: number
      walBytes: number
      checkpoints: number
      checkpointWriteTimeMs: number
      backendWrites: number
    }
    items: IoTelemetryItem[]
    capabilities: IoTelemetryCapability[]
    contexts: IoContextTelemetryItem[]
    servers: ServerOperationTelemetryItem[]
  }
}

export interface ApiResult<T> {
  data: T
  source: 'api' | 'demo'
}

export interface ApiErrorShape {
  status?: number
  message: string
  path: string
}
