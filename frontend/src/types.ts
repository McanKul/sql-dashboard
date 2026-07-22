export type PageId = 'overview' | 'queries' | 'health'

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
  impactScore: number
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
  p95DurationMs: number
  rowsPerCall: number
  sharedBlocksHit: number
  sharedBlocksRead: number
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
