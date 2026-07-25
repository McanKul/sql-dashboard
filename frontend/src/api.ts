import { demoHealth, demoOverview, demoQueries, demoQueryDetails } from './demoData'
import type {
  ApiErrorShape,
  ApiList,
  ApiResult,
  DatabaseOption,
  CompositeIndexCandidate,
  IndexTelemetryItem,
  IoTelemetryItem,
  OperationsData,
  OverviewStats,
  QueryDetail,
  QueryFinding,
  QueryIndexAdvice,
  QueryPredicate,
  QueryListParams,
  QuerySummary,
  ServerOption,
  Severity,
  SystemHealth,
  TimeWindow,
} from './types'
import { comparisonAvailable } from './utils'

const API_BASE = (import.meta.env.VITE_API_BASE_URL || '/api/v1').replace(/\/$/, '')
export const demoModeEnabled = String(import.meta.env.VITE_DEMO_MODE).toLowerCase() === 'true'

export class ApiClientError extends Error {
  status?: number
  path: string

  constructor(shape: ApiErrorShape) {
    super(shape.message)
    this.name = 'ApiClientError'
    this.status = shape.status
    this.path = shape.path
  }
}

interface RawScorePart {
  weight: number
  contribution: number
  score?: number
  percentileScore?: number
  volumeFactor?: number
  absoluteValue?: number
  fullScoreAt?: number
  unit?: string
}

interface RawQuery {
  serverId: number
  serverAlias?: string
  databaseId: number
  databaseName: string
  queryId: string | number
  sql: string
  sqlVisible: boolean
  calls: number
  totalExecTimeMs: number
  meanExecTimeMs: number
  dbLoadPercent: number
  sharedBlocksHit: number
  sharedBlocksRead: number
  tempBlocksWritten: number
  walBytes: number
  cpu?: {
    capability?: {
      available?: boolean
      version?: string | null
      dataAvailable?: boolean
      source?: string
      coverage?: 'EXECUTION_ONLY'
      reason?: string
    }
    userTimeMs?: number | null
    systemTimeMs?: number | null
    totalTimeMs?: number | null
    percentOfExecTime?: number | null
    filesystemReadsBytes?: number | null
    filesystemWritesBytes?: number | null
    scoreIncluded?: false
  }
  waits?: {
    capability?: {
      available?: boolean
      version?: string | null
      release?: string
      dataAvailable?: boolean
      source?: string
      coverage?: 'TOP_LEVEL_SAMPLED_WAITS'
      reason?: string
    }
    totalSamples?: number | null
    categories?: {
      io?: number; lock?: number; lwlock?: number; client?: number; ipc?: number
      timeout?: number; activity?: number; extension?: number; other?: number
    } | null
    dominant?: {
      category?: string; event?: string; sharePercent?: number; confidence?: 'LOW' | 'MEDIUM'
    } | null
    events?: Array<{
      category?: string; eventType?: string; event?: string; samples?: number; sharePercent?: number
    }>
    scoreIncluded?: false
  }
  observedFrom?: string | null
  observedTo?: string | null
  coveragePercent?: number | null
  resetDetected?: boolean
  comparisonReliable?: boolean
  warmingUp?: boolean
  previousPeriodAvailable?: boolean
  previousCalls: number | null
  previousMeanExecTimeMs: number | null
  regressionPercent: number | null
  impactScore: number
  priority: string
  status: string
  note?: string | null
  updatedBy?: string | null
  updatedAt?: string | null
  findings: string[]
  scoreBreakdown: Record<string, RawScorePart>
  p95DurationMs?: number | null
  p95ExecTimeMs?: number | null
  rows?: number | null
  rowsPerCall?: number | null
  durationDistribution?: { available?: boolean; reason?: string } | null
}

interface RawQueryDetail extends RawQuery {
  trend: Array<{ timestamp: string; totalExecTimeMs: number; calls: number }>
  comparison: {
    currentMeanMs: number
    previousMeanMs: number | null
    regressionPercent: number | null
    currentCalls: number
    previousCalls: number | null
  }
  recommendations?: { available: boolean; label: string; reason: string } | null
}

interface RawPredicateResponse {
  window: TimeWindow
  queryId: string
  capability: {
    available: boolean
    version?: string | null
    dataAvailable: boolean
    coverage: 'WHERE_FILTER_ONLY' | 'WHERE_AND_JOIN_SNAPSHOT'
    joinsAvailable: boolean
    ddlGenerated: boolean
    reason: string
    observedFrom?: string | null
    observedTo?: string | null
  }
  items: Array<{
    qualId: string
    relationId: number
    schemaName: string
    tableName: string
    columns: string[]
    operatorOids: number[]
    evalType: 'FILTER' | 'INDEX_CONDITION' | 'UNKNOWN'
    occurrences: number
    rowsProcessed: number
    rowsFiltered: number
    filterRatio?: number | null
    observedFrom: string
    observedTo: string
    sampleCount: number
    signal: 'INDEX_CANDIDATE' | 'REVIEW' | 'INDEX_CONDITION_OBSERVED' | 'OBSERVED' | 'INSUFFICIENT_DATA'
    recommendation: string
  }>
  joinCapability?: {
    available: boolean
    dataAvailable: boolean
    status: 'STARTING' | 'HEALTHY' | 'DEGRADED' | 'ERROR' | 'UNAVAILABLE'
    lastSnapshotAt?: string | null
    lagSeconds?: number | null
    captureMode: 'QUALSTATS_RESET_BOUNDARY'
    reason: string
  }
  joins?: Array<{
    qualId: string
    qualNodeId: string
    leftRelationId: number
    leftSchemaName: string
    leftTableName: string
    leftColumnName: string
    rightRelationId: number
    rightSchemaName: string
    rightTableName: string
    rightColumnName: string
    operatorOid: number
    operatorName?: string | null
    btreeStrategy?: number | null
    occurrences: number
    rowsProcessed: number
    sampleCount: number
    observedFrom: string
    observedTo: string
    signal: 'FREQUENT_JOIN' | 'OBSERVED_JOIN' | 'INSUFFICIENT_DATA'
    scoreIncluded: false
  }>
  candidates?: CompositeIndexCandidate[]
}

interface RawOverview {
  window: string
  cards: {
    totalDbTimeMs: number
    trackedQueries: number
    criticalQueries: number
    regressions: number
    collectorLagSeconds: number | null
  }
  topQueries: RawQuery[]
  trend: Array<{ timestamp: string; totalExecTimeMs: number; calls: number }>
  collector: null | {
    serverId: number
    alias?: string
    hostname?: string
    lastSnapshotAt?: string | null
    lagSeconds?: number | null
    status?: string
    errors?: string[]
  }
}

interface RawSystemHealth {
  summary: { tablesObserved: number; critical: number; warnings: number; notices: number }
  capabilities: Array<{ key: string; label: string; available: boolean; source: string; reason?: string }>
  items: Array<{
    serverId: number
    serverAlias?: string
    databaseId: number
    databaseName: string
    relationId: number
    relationName: string
    sampleAt?: string | null
    tableSizeBytes: number
    seqScan: number
    seqTuplesRead: number
    indexScan: number
    liveTuples: number
    deadTuples: number
    deadTuplePercent: number
    lastAutovacuum?: string | null
    signalLevel: string
    recommendation?: string | null
  }>
  longTransactions?: Array<{ databaseName: string; ageSeconds: number }>
}

interface RawOperations {
  architecture?: {
    host?: string
    source?: { count?: number }
    dataFlow?: string[]
    apiSourceConnection?: boolean
  }
  services?: Array<{ name?: string; service?: string; status?: string }>
  collector?: Record<string, unknown> | null
  collectors?: Array<Record<string, unknown>>
  repository?: {
    postgresVersion?: string
    powaVersion?: string
    sizeBytes?: number
    retentionDays?: number
  }
}

function unwrap<T>(payload: unknown): T {
  if (payload && typeof payload === 'object' && 'data' in payload) return (payload as { data: T }).data
  return payload as T
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      Accept: 'application/json',
      'X-Advisor-Role': 'analyst',
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
      ...init?.headers,
    },
  }).catch((cause: unknown) => {
    if (init?.signal?.aborted) throw cause
    throw new ApiClientError({
      path,
      message: cause instanceof Error ? `API bağlantısı kurulamadı: ${cause.message}` : 'API bağlantısı kurulamadı.',
    })
  })

  if (!response.ok) {
    let message = `İstek başarısız oldu (${response.status}).`
    try {
      const body = await response.json() as { detail?: string | Array<{ msg?: string }>; message?: string }
      if (typeof body.detail === 'string') message = body.detail
      else if (Array.isArray(body.detail)) message = body.detail.map((item) => item.msg).filter(Boolean).join(', ') || message
      else if (body.message) message = body.message
    } catch {
      // JSON olmayan yanıtta güvenli genel mesaj korunur.
    }
    throw new ApiClientError({ status: response.status, message, path })
  }

  if (response.status === 204) return undefined as T
  return unwrap<T>(await response.json())
}

const asResult = <T>(data: T, source: 'api' | 'demo'): ApiResult<T> => ({ data, source })
const clamp = (value: number, min = 0, max = 100) => Math.max(min, Math.min(max, Number.isFinite(value) ? value : 0))
const optionalNumber = (value: unknown): number | undefined => {
  if (value === null || value === undefined || value === '') return undefined
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : undefined
}
const recordValue = (record: Record<string, unknown> | null | undefined, ...keys: string[]): unknown => {
  for (const key of keys) {
    if (record && record[key] !== undefined && record[key] !== null) return record[key]
  }
  return undefined
}

const severityFromPriority = (priority?: string): Severity => {
  switch ((priority || '').toUpperCase()) {
    case 'CRITICAL': return 'critical'
    case 'HIGH':
    case 'MEDIUM': return 'warning'
    default: return 'healthy'
  }
}

const queryKey = (query: Pick<RawQuery, 'serverId' | 'databaseId' | 'queryId'>) => `${query.serverId}:${query.databaseId}:${String(query.queryId)}`

function parseQueryKey(id: string): { serverId?: number; databaseId?: number; queryId: string } {
  const [server, database, ...queryParts] = id.split(':')
  if (queryParts.length && Number.isFinite(Number(server)) && Number.isFinite(Number(database))) {
    return { serverId: Number(server), databaseId: Number(database), queryId: queryParts.join(':') }
  }
  return { queryId: id }
}

function queryTitle(query: RawQuery): string {
  const sql = (query.sql || '').trim()
  const verb = (sql.match(/^([a-z]+)/i)?.[1] || 'SQL').toUpperCase()
  const relation = sql.match(/\b(?:from|update|into|delete\s+from)\s+([\w."-]+)/i)?.[1]?.replaceAll('"', '')
  return relation ? `${verb} · ${relation}` : `${verb} sorgusu · ${query.databaseName}`
}

function mapSummary(query: RawQuery, observedAt?: string): QuerySummary {
  const impactScore = clamp(Number(query.impactScore))
  const cpuAvailable = Boolean(query.cpu?.capability?.available)
  const cpuDataAvailable = cpuAvailable && Boolean(query.cpu?.capability?.dataAvailable)
  const waitAvailable = Boolean(query.waits?.capability?.available)
  const waitDataAvailable = waitAvailable && Boolean(query.waits?.capability?.dataAvailable)
  const previousPeriodAvailable = query.previousPeriodAvailable
    ?? (query.previousCalls !== null && query.previousCalls !== undefined
      && query.previousMeanExecTimeMs !== null && query.previousMeanExecTimeMs !== undefined)
  const resetDetected = Boolean(query.resetDetected)
  const comparisonReliable = previousPeriodAvailable
    && !resetDetected
    && (query.comparisonReliable ?? true)
  const warmingUp = query.warmingUp ?? !previousPeriodAvailable
  const regressionPercent = comparisonReliable ? optionalNumber(query.regressionPercent) : undefined
  const calls = Number(query.calls || 0)
  return {
    id: queryKey(query),
    queryId: String(query.queryId),
    serverId: Number(query.serverId),
    serverAlias: query.serverAlias || `server-${query.serverId}`,
    databaseId: Number(query.databaseId),
    fingerprint: String(query.queryId),
    title: queryTitle(query),
    sqlPreview: query.sql,
    database: query.serverAlias ? `${query.serverAlias} / ${query.databaseName}` : query.databaseName,
    calls,
    avgDurationMs: Number(query.meanExecTimeMs || 0),
    totalTimeMs: Number(query.totalExecTimeMs || 0),
    dbLoadPercent: Number(query.dbLoadPercent || 0),
    sharedBlocksHit: Number(query.sharedBlocksHit || 0),
    sharedBlocksRead: Number(query.sharedBlocksRead || 0),
    tempBlocksWritten: Number(query.tempBlocksWritten || 0),
    walBytes: Number(query.walBytes || 0),
    cpu: {
      capability: {
        available: cpuAvailable,
        version: query.cpu?.capability?.version,
        dataAvailable: cpuDataAvailable,
        source: query.cpu?.capability?.source || 'PoWA pg_stat_kcache',
        coverage: 'EXECUTION_ONLY',
        reason: query.cpu?.capability?.reason || 'pg_stat_kcache telemetrisi kullanilamiyor.',
      },
      userTimeMs: cpuDataAvailable ? optionalNumber(query.cpu?.userTimeMs) ?? null : null,
      systemTimeMs: cpuDataAvailable ? optionalNumber(query.cpu?.systemTimeMs) ?? null : null,
      totalTimeMs: cpuDataAvailable ? optionalNumber(query.cpu?.totalTimeMs) ?? null : null,
      percentOfExecTime: cpuDataAvailable ? optionalNumber(query.cpu?.percentOfExecTime) ?? null : null,
      filesystemReadsBytes: cpuDataAvailable ? optionalNumber(query.cpu?.filesystemReadsBytes) ?? null : null,
      filesystemWritesBytes: cpuDataAvailable ? optionalNumber(query.cpu?.filesystemWritesBytes) ?? null : null,
      scoreIncluded: false,
    },
    waits: {
      capability: {
        available: waitAvailable,
        version: query.waits?.capability?.version,
        release: query.waits?.capability?.release || '1.1.11',
        dataAvailable: waitDataAvailable,
        source: query.waits?.capability?.source || 'PoWA pg_wait_sampling',
        coverage: 'TOP_LEVEL_SAMPLED_WAITS',
        reason: query.waits?.capability?.reason || 'pg_wait_sampling telemetrisi kullanilamiyor.',
      },
      totalSamples: waitDataAvailable ? optionalNumber(query.waits?.totalSamples) ?? 0 : null,
      categories: waitDataAvailable ? {
        io: Number(query.waits?.categories?.io || 0),
        lock: Number(query.waits?.categories?.lock || 0),
        lwlock: Number(query.waits?.categories?.lwlock || 0),
        client: Number(query.waits?.categories?.client || 0),
        ipc: Number(query.waits?.categories?.ipc || 0),
        timeout: Number(query.waits?.categories?.timeout || 0),
        activity: Number(query.waits?.categories?.activity || 0),
        extension: Number(query.waits?.categories?.extension || 0),
        other: Number(query.waits?.categories?.other || 0),
      } : null,
      dominant: waitDataAvailable && query.waits?.dominant?.event ? {
        category: query.waits.dominant.category || 'OTHER',
        event: query.waits.dominant.event,
        sharePercent: Number(query.waits.dominant.sharePercent || 0),
        confidence: query.waits.dominant.confidence || 'LOW',
      } : null,
      events: waitDataAvailable ? (query.waits?.events || []).map((event) => ({
        category: event.category || 'OTHER',
        eventType: event.eventType || 'Unknown',
        event: event.event || 'Unknown',
        samples: Number(event.samples || 0),
        sharePercent: Number(event.sharePercent || 0),
      })) : [],
      scoreIncluded: false,
    },
    observedFrom: query.observedFrom || null,
    observedTo: query.observedTo || null,
    coveragePercent: optionalNumber(query.coveragePercent) ?? null,
    resetDetected,
    comparisonReliable,
    warmingUp,
    previousPeriodAvailable,
    impactScore: Math.round(impactScore),
    priority: (query.priority || 'LOW').toUpperCase(),
    severity: severityFromPriority(query.priority),
    lastSeenAt: query.observedTo || observedAt || query.updatedAt || '',
    changePercent: regressionPercent ?? null,
    hasComparison: comparisonReliable
      && previousPeriodAvailable
      && regressionPercent !== undefined
      && comparisonAvailable(Number(query.previousCalls), calls),
  }
}

const scoreLabels: Record<string, { label: string; hint: string }> = {
  totalTime: { label: 'Toplam süre', hint: 'Veritabanı zamanındaki ağırlıklı pay' },
  physicalRead: { label: 'Okunan shared blok', hint: 'PostgreSQL shared block okuma yükü' },
  callFrequency: { label: 'Çağrı sıklığı', hint: 'Zaman aralığındaki yürütme sayısı' },
  tempWrite: { label: 'Geçici yazma', hint: 'Sıralama ve hash işlemlerinin disk etkisi' },
  regression: { label: 'Regresyon', hint: 'Önceki eş döneme göre değişim' },
  wal: { label: 'WAL üretimi', hint: 'Sorgunun ürettiği WAL hacmi' },
}

function mapFindings(query: RawQueryDetail): QueryFinding[] {
  return (query.findings || []).map((finding, index) => ({
    id: `finding-${index}`,
    severity: index === 0 ? severityFromPriority(query.priority) : 'warning',
    title: index === 0 ? 'Öncelikli telemetri sinyali' : `Telemetri sinyali ${index + 1}`,
    description: finding,
    recommendation: 'Bulguyu sorgu planı ve seçili dönemdeki gerçek yük ile doğrulayın.',
  }))
}

function labelForTimestamp(timestamp: string): string {
  const date = new Date(timestamp)
  if (Number.isNaN(date.getTime())) return '—'
  return new Intl.DateTimeFormat('tr-TR', { day: '2-digit', month: 'short', hour: '2-digit' }).format(date)
}

function mapDetail(query: RawQueryDetail, predicatePayload: RawPredicateResponse): QueryDetail {
  const observedAt = query.observedTo || query.trend.at(-1)?.timestamp || query.updatedAt || ''
  const summary = mapSummary(query, observedAt)
  const breakdown = Object.entries(query.scoreBreakdown || {}).map(([key, part]) => {
    const maxContribution = Math.round(Number(part.weight || 0) * 100)
    return {
      key,
      label: scoreLabels[key]?.label || key,
      contribution: clamp(Number(part.contribution || 0), 0, maxContribution),
      maxContribution,
      hint: scoreLabels[key]?.hint || 'Ağırlıklı etki bileşeni',
      percentileScore: optionalNumber(part.percentileScore ?? part.score),
      volumeFactor: optionalNumber(part.volumeFactor),
      absoluteValue: optionalNumber(part.absoluteValue),
      fullScoreAt: optionalNumber(part.fullScoreAt),
      unit: part.unit,
    }
  })
  const previousMean = optionalNumber(query.comparison?.previousMeanMs)
  const previousCalls = optionalNumber(query.comparison?.previousCalls)
  const previousTotal = previousMean !== undefined && previousCalls !== undefined
    ? previousMean * previousCalls
    : undefined
  const currentTotal = Number(query.comparison?.currentMeanMs || 0) * Number(query.comparison?.currentCalls || 0)
  const regression = summary.hasComparison
    ? optionalNumber(query.comparison?.regressionPercent)
    : undefined

  return {
    ...summary,
    fullSql: query.sql,
    firstSeenAt: query.observedFrom || query.trend[0]?.timestamp || observedAt,
    p95DurationMs: optionalNumber(query.p95ExecTimeMs ?? query.p95DurationMs),
    rowsPerCall: optionalNumber(query.rowsPerCall),
    durationDistribution: query.durationDistribution ? { available: Boolean(query.durationDistribution.available), reason: query.durationDistribution.reason } : undefined,
    trend: (query.trend || []).map((point) => ({
      label: labelForTimestamp(point.timestamp),
      durationMs: point.calls ? Number(point.totalExecTimeMs || 0) / point.calls : 0,
      impactScore: summary.impactScore,
    })),
    scoreBreakdown: breakdown,
    comparison: summary.hasComparison
      && regression !== undefined
      && previousMean !== undefined
      && previousCalls !== undefined
      && previousTotal !== undefined
      ? [
          { metric: 'Ort. çalışma süresi', before: previousMean, after: Number(query.comparison?.currentMeanMs || 0), unit: 'ms', improvementPercent: -regression },
          { metric: 'Çağrı', before: previousCalls, after: Number(query.comparison?.currentCalls || 0), unit: 'adet', improvementPercent: previousCalls ? ((previousCalls - query.comparison.currentCalls) / previousCalls) * 100 : 0 },
          { metric: 'Toplam çalışma', before: previousTotal, after: currentTotal, unit: 'ms', improvementPercent: previousTotal ? ((previousTotal - currentTotal) / previousTotal) * 100 : 0 },
        ]
      : [],
    findings: mapFindings(query),
    predicates: {
      capability: predicatePayload.capability,
      items: predicatePayload.items.map((item) => ({
        ...item,
        qualId: String(item.qualId),
        relationId: Number(item.relationId),
        columns: Array.isArray(item.columns) ? item.columns : [],
        operatorOids: Array.isArray(item.operatorOids) ? item.operatorOids.map(Number) : [],
        occurrences: Number(item.occurrences || 0),
        rowsProcessed: Number(item.rowsProcessed || 0),
        rowsFiltered: Number(item.rowsFiltered || 0),
        filterRatio: optionalNumber(item.filterRatio),
        sampleCount: Number(item.sampleCount || 0),
      })),
      joinCapability: predicatePayload.joinCapability || {
        available: false,
        dataAvailable: false,
        status: 'UNAVAILABLE',
        captureMode: 'QUALSTATS_RESET_BOUNDARY',
        reason: 'JOIN snapshotter bu kaynak icin yapilandirilmamis.',
      },
      joins: (predicatePayload.joins || []).map((item) => ({
        ...item,
        qualId: String(item.qualId),
        qualNodeId: String(item.qualNodeId),
        leftRelationId: Number(item.leftRelationId),
        rightRelationId: Number(item.rightRelationId),
        operatorOid: Number(item.operatorOid),
        btreeStrategy: optionalNumber(item.btreeStrategy),
        occurrences: Number(item.occurrences || 0),
        rowsProcessed: Number(item.rowsProcessed || 0),
        sampleCount: Number(item.sampleCount || 0),
        scoreIncluded: false,
      })),
      candidates: (predicatePayload.candidates || []).map((item) => ({
        ...item,
        candidateId: String(item.candidateId),
        serverId: Number(item.serverId),
        databaseId: Number(item.databaseId),
        queryId: String(item.queryId),
        relationId: Number(item.relationId),
        columns: item.columns,
        operatorOids: (item.operatorOids || []).map(Number),
        joinOccurrences: Number(item.joinOccurrences || 0),
        filterOccurrences: Number(item.filterOccurrences || 0),
        rowsProcessed: Number(item.rowsProcessed || 0),
        rowsFiltered: Number(item.rowsFiltered || 0),
        filterRatio: optionalNumber(item.filterRatio),
        sampleCount: Number(item.sampleCount || 0),
        existingIndexChecked: Boolean(item.existingIndexChecked),
        runtimeFixtureAvailable: Boolean(item.runtimeFixtureAvailable),
        scoreIncluded: false,
      })),
    },
  }
}

function mapOverview(raw: RawOverview): OverviewStats {
  const observedAt = raw.collector?.lastSnapshotAt || raw.trend.at(-1)?.timestamp || new Date().toISOString()
  const latencyTrend = raw.trend.map((point) => ({
    label: labelForTimestamp(point.timestamp),
    value: point.calls ? Number(point.totalExecTimeMs || 0) / point.calls : 0,
  }))
  const collectorHealthy = (raw.collector?.status || '').toUpperCase() === 'HEALTHY'

  return {
    databaseName: raw.collector?.alias || raw.collector?.hostname || 'PoWA repository',
    environment: 'Canlı telemetri',
    lastCollectedAt: observedAt,
    queriesAnalyzed: Number(raw.cards.trackedQueries || 0),
    criticalQueries: Number(raw.cards.criticalQueries || 0),
    regressions: Number(raw.cards.regressions || 0),
    databaseTimeHours: Number(raw.cards.totalDbTimeMs || 0) / 3_600_000,
    latencyTrend,
    recentActivity: [
      { id: 'collector', title: collectorHealthy ? 'Collector sağlıklı' : 'Collector kontrol edilmeli', detail: `Gecikme: ${raw.cards.collectorLagSeconds ?? 'ölçülemedi'} saniye`, occurredAt: observedAt, tone: collectorHealthy ? 'healthy' : 'warning' },
      { id: 'queries', title: `${raw.cards.trackedQueries} sorgu izlendi`, detail: `${raw.cards.criticalQueries} kritik öncelikli sorgu`, occurredAt: observedAt, tone: raw.cards.criticalQueries ? 'warning' : 'healthy' },
      { id: 'regressions', title: `${raw.cards.regressions} regresyon sinyali`, detail: 'Önceki eş zaman aralığıyla karşılaştırıldı', occurredAt: observedAt, tone: raw.cards.regressions ? 'critical' : 'healthy' },
    ],
    opportunities: raw.topQueries.slice(0, 3).map((query) => ({
      queryId: queryKey(query),
      title: queryTitle(query),
      averageMs: Number(query.meanExecTimeMs || 0),
      loadPercent: Number(query.dbLoadPercent || 0),
    })),
  }
}

function mapSystemHealth(raw: RawSystemHealth): SystemHealth {
  const timestamps = raw.items.map((item) => item.sampleAt).filter((value): value is string => Boolean(value))
  const observedAt = timestamps.sort().at(-1) || new Date().toISOString()
  const longTransactionCount = raw.longTransactions?.length || 0
  const metric = (key: string, label: string, value: number, target: string, severity: Severity, description: string) => ({
    key, label, value, unit: 'adet', target, severity, description, history: [{ label: 'Şimdi', value }],
  })
  const grouped = new Map<string, SystemHealth['databases'][number]>()
  for (const item of raw.items) {
    const groupKey = `${item.serverId}:${item.databaseId}`
    const current = grouped.get(groupKey) || { serverId: item.serverId, databaseId: item.databaseId, name: item.serverAlias ? `${item.serverAlias} / ${item.databaseName}` : item.databaseName, sizeGb: 0, tableCount: 0, sequentialScans: 0, indexScans: 0, deadTuples: 0, signals: 0, severity: 'healthy' as Severity }
    current.sizeGb += Number(item.tableSizeBytes || 0) / 1_073_741_824
    current.tableCount += 1
    current.sequentialScans += Number(item.seqScan || 0)
    current.indexScans += Number(item.indexScan || 0)
    current.deadTuples += Number(item.deadTuples || 0)
    const signalLevel = item.signalLevel.toUpperCase()
    if (signalLevel !== 'HEALTHY') current.signals += 1
    if (signalLevel === 'CRITICAL') current.severity = 'critical'
    else if (signalLevel !== 'HEALTHY' && current.severity !== 'critical') current.severity = 'warning'
    grouped.set(groupKey, current)
  }
  const overall: Severity = raw.summary.critical > 0 ? 'critical' : raw.summary.warnings > 0 || raw.summary.notices > 0 || longTransactionCount > 0 ? 'warning' : 'healthy'
  const followUpSignals = raw.summary.warnings + raw.summary.notices

  return {
    collectedAt: observedAt,
    postgresVersion: 'Canlı tablo ölçümleri',
    overall,
    metrics: [
      metric('observed', 'İzlenen tablo', raw.summary.tablesObserved, '> 0', raw.summary.tablesObserved ? 'healthy' : 'warning', 'İstatistiği alınan tablolar'),
      metric('critical', 'Kritik sinyal', raw.summary.critical, '0', raw.summary.critical ? 'critical' : 'healthy', 'Öncelikli inceleme gerektiren tablolar'),
      metric('follow-up', 'Takip sinyali', followUpSignals, '0', followUpSignals ? 'warning' : 'healthy', `${raw.summary.warnings} uyarı, ${raw.summary.notices} izleme sinyali`),
      metric('transactions', 'Uzun işlem', longTransactionCount, '0', longTransactionCount ? 'warning' : 'healthy', 'Uzun süre açık kalan işlemler'),
    ],
    databases: [...grouped.values()],
    capabilities: raw.capabilities,
  }
}

function mapCollector(raw: Record<string, unknown> | null | undefined): OperationsData['collector'] {
  return {
    alias: String(recordValue(raw, 'alias') || ''),
    hostname: String(recordValue(raw, 'hostname', 'host') || ''),
    port: optionalNumber(recordValue(raw, 'port')),
    frequencySeconds: optionalNumber(recordValue(raw, 'frequencySeconds', 'frequency')),
    retention: recordValue(raw, 'retention') == null ? null : String(recordValue(raw, 'retention')),
    lastSnapshotAt: recordValue(raw, 'lastSnapshotAt', 'last_snapshot_at') == null ? null : String(recordValue(raw, 'lastSnapshotAt', 'last_snapshot_at')),
    lagSeconds: optionalNumber(recordValue(raw, 'lagSeconds', 'lag_seconds')),
    status: String(recordValue(raw, 'status') || 'UNKNOWN'),
    errors: Array.isArray(recordValue(raw, 'errors')) ? (recordValue(raw, 'errors') as unknown[]).map(String) : [],
  }
}

function payloadItems(payload: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(payload)) return payload.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === 'object')
  if (payload && typeof payload === 'object') {
    const record = payload as Record<string, unknown>
    const nested = record.items ?? record.databases ?? record.data
    if (Array.isArray(nested)) return nested.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === 'object')
  }
  return []
}

function mapIndexItems(payload: unknown): IndexTelemetryItem[] {
  return payloadItems(payload).map((item) => ({
    serverId: Number(recordValue(item, 'serverId', 'server_id') || 0),
    serverAlias: String(recordValue(item, 'serverAlias', 'server_alias') || ''),
    databaseId: Number(recordValue(item, 'databaseId', 'database_id') || 0),
    databaseName: String(recordValue(item, 'databaseName', 'database_name') || '—'),
    relationId: optionalNumber(recordValue(item, 'relationId', 'relation_id')),
    indexId: optionalNumber(recordValue(item, 'indexId', 'index_id')),
    schemaName: String(recordValue(item, 'schemaName', 'schema_name') || ''),
    tableName: String(recordValue(item, 'tableName', 'table_name', 'relationName', 'relation_name') || '—'),
    indexName: String(recordValue(item, 'indexName', 'index_name') || '—'),
    indexSizeBytes: Number(recordValue(item, 'indexSizeBytes', 'index_size_bytes', 'sizeBytes', 'size_bytes') || 0),
    indexScans: Number(recordValue(item, 'indexScans', 'index_scans', 'idxScan', 'idx_scan', 'scans') || 0),
    tuplesRead: optionalNumber(recordValue(item, 'tuplesRead', 'tuples_read')),
    tuplesFetched: optionalNumber(recordValue(item, 'tuplesFetched', 'tuples_fetched')),
    blocksRead: optionalNumber(recordValue(item, 'blocksRead', 'blocks_read')),
    blocksHit: optionalNumber(recordValue(item, 'blocksHit', 'blocks_hit')),
    cacheHitPercent: optionalNumber(recordValue(item, 'cacheHitPercent', 'cache_hit_percent')) ?? null,
    tableWrites: optionalNumber(recordValue(item, 'tableWrites', 'table_writes', 'writes')),
    lastUsedAt: recordValue(item, 'lastUsedAt', 'last_used_at', 'lastScanAt', 'last_scan_at') == null ? null : String(recordValue(item, 'lastUsedAt', 'last_used_at', 'lastScanAt', 'last_scan_at')),
    signalLevel: String(recordValue(item, 'signalLevel', 'signal_level', 'status') || ''),
    signal: String(recordValue(item, 'signal') || ''),
    recommendation: recordValue(item, 'recommendation') == null ? null : String(recordValue(item, 'recommendation')),
  }))
}

function mapIoItems(payload: unknown): IoTelemetryItem[] {
  return payloadItems(payload).map((item) => ({
    serverId: Number(recordValue(item, 'serverId', 'server_id') || 0),
    serverAlias: String(recordValue(item, 'serverAlias', 'server_alias') || ''),
    databaseId: Number(recordValue(item, 'databaseId', 'database_id') || 0),
    databaseName: String(recordValue(item, 'databaseName', 'database_name') || '—'),
    sampleAt: recordValue(item, 'sampleAt', 'sample_at') == null ? null : String(recordValue(item, 'sampleAt', 'sample_at')),
    sharedBlocksHit: Number(recordValue(item, 'sharedBlocksHit', 'shared_blocks_hit', 'blksHit', 'blks_hit', 'blocksHit', 'blocks_hit') || 0),
    sharedBlocksRead: Number(recordValue(item, 'sharedBlocksRead', 'shared_blocks_read', 'blksRead', 'blks_read', 'blocksRead', 'blocks_read') || 0),
    tempBlocksWritten: Number(recordValue(item, 'tempBlocksWritten', 'temp_blocks_written', 'tempBlksWritten', 'temp_blks_written') || 0),
    tempBytes: optionalNumber(recordValue(item, 'tempBytes', 'temp_bytes')),
    walBytes: Number(recordValue(item, 'walBytes', 'wal_bytes') || 0),
    readTimeMs: optionalNumber(recordValue(item, 'readTimeMs', 'read_time_ms', 'blkReadTime', 'blk_read_time', 'blockReadTimeMs')),
    writeTimeMs: optionalNumber(recordValue(item, 'writeTimeMs', 'write_time_ms', 'blkWriteTime', 'blk_write_time', 'blockWriteTimeMs')),
    currentBackends: optionalNumber(recordValue(item, 'currentBackends')),
    transactionsCommitted: optionalNumber(recordValue(item, 'transactionsCommitted')),
    transactionsRolledBack: optionalNumber(recordValue(item, 'transactionsRolledBack')),
    tempFiles: optionalNumber(recordValue(item, 'tempFiles')),
    deadlocks: optionalNumber(recordValue(item, 'deadlocks')),
    tuplesReturned: optionalNumber(recordValue(item, 'tuplesReturned')),
    tuplesFetched: optionalNumber(recordValue(item, 'tuplesFetched')),
    tuplesInserted: optionalNumber(recordValue(item, 'tuplesInserted')),
    tuplesUpdated: optionalNumber(recordValue(item, 'tuplesUpdated')),
    tuplesDeleted: optionalNumber(recordValue(item, 'tuplesDeleted')),
  }))
}

function mapOperations(raw: RawOperations, indexes: OperationsData['indexes'], io: OperationsData['io']): OperationsData {
  const collectors = (raw.collectors || []).map((collector) => ({
    serverId: optionalNumber(recordValue(collector, 'serverId', 'server_id')),
    ...mapCollector(collector),
  }))
  return {
    architecture: {
      host: raw.architecture?.host,
      dataFlow: raw.architecture?.dataFlow || [],
      apiSourceConnection: raw.architecture?.apiSourceConnection,
      sourceCount: Number(raw.architecture?.source?.count ?? collectors.length),
    },
    services: (raw.services || []).map((service) => ({
      name: service.name || service.service || 'Servis',
      service: service.service || service.name || 'unknown',
      status: service.status || 'UNKNOWN',
    })),
    collector: mapCollector(raw.collector),
    collectors,
    repository: {
      postgresVersion: raw.repository?.postgresVersion,
      powaVersion: raw.repository?.powaVersion,
      sizeBytes: Number(raw.repository?.sizeBytes || 0),
      retentionDays: Number(raw.repository?.retentionDays || 0),
    },
    indexes,
    io,
  }
}

export const advisorApi = {
  async getOverview(window: TimeWindow = '24h', signal?: AbortSignal): Promise<ApiResult<OverviewStats>> {
    if (demoModeEnabled) return asResult(demoOverview, 'demo')
    return asResult(mapOverview(await request<RawOverview>(`/overview?window=${window}`, { signal })), 'api')
  },

  async getQueries(window: TimeWindow = '24h', params: QueryListParams = { page: 1, pageSize: 50 }, signal?: AbortSignal): Promise<ApiResult<ApiList<QuerySummary>>> {
    if (demoModeEnabled) return asResult({ items: demoQueries, total: demoQueries.length }, 'demo')
    const search = new URLSearchParams({ window, page: String(params.page), pageSize: String(params.pageSize), sort: params.sort || 'impact' })
    if (params.search?.trim()) search.set('search', params.search.trim())
    if (params.priority) search.set('priority', params.priority)
    if (params.serverId !== undefined) search.set('serverId', String(params.serverId))
    if (params.databaseId !== undefined) search.set('databaseId', String(params.databaseId))
    if (params.minCalls) search.set('minCalls', String(params.minCalls))
    if (params.minDurationMs) search.set('minDurationMs', String(params.minDurationMs))
    const payload = await request<{ items: RawQuery[]; total: number; page?: number; pageSize?: number; window?: TimeWindow }>(`/queries?${search}`, { signal })
    return asResult({ items: payload.items.map((query) => mapSummary(query)), total: payload.total, page: payload.page ?? params.page, pageSize: payload.pageSize ?? params.pageSize, window: payload.window ?? window }, 'api')
  },

  async getQuery(id: string, window: TimeWindow = '24h', signal?: AbortSignal): Promise<ApiResult<QueryDetail>> {
    if (demoModeEnabled) {
      const detail = demoQueryDetails[id]
      if (!detail) throw new ApiClientError({ status: 404, path: `/queries/${id}`, message: 'Sorgu bulunamadı.' })
      return asResult(detail, 'demo')
    }
    const key = parseQueryKey(id)
    const params = new URLSearchParams()
    params.set('window', window)
    if (key.serverId !== undefined) params.set('serverId', String(key.serverId))
    if (key.databaseId !== undefined) params.set('databaseId', String(key.databaseId))
    const suffix = params.size ? `?${params.toString()}` : ''
    const detailPath = `/queries/${encodeURIComponent(key.queryId)}${suffix}`
    const [detail, predicates] = await Promise.all([
      request<RawQueryDetail>(detailPath, { signal }),
      request<RawPredicateResponse>(`/queries/${encodeURIComponent(key.queryId)}/predicates${suffix}`, { signal }),
    ])
    return asResult(mapDetail(detail, predicates), 'api')
  },

  async evaluateIndex(id: string, window: TimeWindow, predicate: QueryPredicate, signal?: AbortSignal): Promise<ApiResult<QueryIndexAdvice>> {
    if (demoModeEnabled) return asResult({ status: 'UNAVAILABLE', reasonCode: 'DEMO_MODE', message: 'HypoPG dogrulamasi demo verisinde calistirilmaz.', ddlExecuted: false }, 'demo')
    const key = parseQueryKey(id)
    if (key.serverId === undefined || key.databaseId === undefined) {
      throw new ApiClientError({ path: `/queries/${key.queryId}/index-evaluations`, message: 'HypoPG icin sunucu ve veritabani kimligi gerekli.' })
    }
    const payload = await request<QueryIndexAdvice>(
      `/queries/${encodeURIComponent(key.queryId)}/index-evaluations?window=${window}`,
      {
        method: 'POST',
        signal,
        body: JSON.stringify({
          serverId: key.serverId,
          databaseId: key.databaseId,
          qualId: predicate.qualId,
          relationId: predicate.relationId,
        }),
      },
    )
    return asResult(payload, 'api')
  },

  async evaluateCompositeIndex(id: string, window: TimeWindow, candidate: CompositeIndexCandidate, signal?: AbortSignal): Promise<ApiResult<QueryIndexAdvice>> {
    if (demoModeEnabled) return asResult({ status: 'UNAVAILABLE', reasonCode: 'DEMO_MODE', message: 'Composite HypoPG dogrulamasi demo verisinde calistirilmaz.', ddlExecuted: false }, 'demo')
    const key = parseQueryKey(id)
    if (key.serverId === undefined || key.databaseId === undefined) {
      throw new ApiClientError({ path: `/queries/${key.queryId}/composite-index-evaluations`, message: 'Composite HypoPG icin sunucu ve veritabani kimligi gerekli.' })
    }
    const payload = await request<QueryIndexAdvice>(
      `/queries/${encodeURIComponent(key.queryId)}/composite-index-evaluations?window=${window}`,
      {
        method: 'POST',
        signal,
        body: JSON.stringify({
          serverId: key.serverId,
          databaseId: key.databaseId,
          candidateId: candidate.candidateId,
        }),
      },
    )
    return asResult(payload, 'api')
  },

  async getSystemHealth(signal?: AbortSignal): Promise<ApiResult<SystemHealth>> {
    if (demoModeEnabled) return asResult(demoHealth, 'demo')
    return asResult(mapSystemHealth(await request<RawSystemHealth>('/system-health', { signal })), 'api')
  },

  async getServers(signal?: AbortSignal): Promise<ApiResult<ServerOption[]>> {
    if (demoModeEnabled) return asResult([{ id: 1, alias: 'demo-source', hostname: 'localhost', database: 'postgres' }], 'demo')
    const payload = await request<{ items: ServerOption[] }>('/servers', { signal })
    return asResult(payload.items || [], 'api')
  },

  async getDatabases(serverId?: number, signal?: AbortSignal): Promise<ApiResult<DatabaseOption[]>> {
    if (demoModeEnabled) {
      const items = [...new Map(demoQueries.map((query) => [`${query.serverId}:${query.databaseId}`, { serverId: query.serverId, databaseId: query.databaseId, name: query.database.split(' / ').at(-1) || query.database }])).values()]
      return asResult(serverId === undefined ? items : items.filter((item) => item.serverId === serverId), 'demo')
    }
    const suffix = serverId === undefined ? '' : `?serverId=${serverId}`
    const payload = await request<{ items: DatabaseOption[] }>(`/databases${suffix}`, { signal })
    return asResult(payload.items || [], 'api')
  },

  async getOperations(window: TimeWindow = '24h', signal?: AbortSignal): Promise<ApiResult<OperationsData>> {
    const demoRaw: RawOperations = {
      architecture: { host: 'Demo host', source: { count: 1 }, dataFlow: ['PostgreSQL kaynakları', 'collector', 'repository-db', 'api', 'web'], apiSourceConnection: false },
      services: [{ name: 'PoWA Collector', service: 'collector', status: 'HEALTHY' }, { name: 'PostgreSQL repository', service: 'repository-db', status: 'HEALTHY' }],
      collector: { alias: 'demo-source', status: 'HEALTHY', lagSeconds: 4, frequencySeconds: 30, retention: '90 days' },
      repository: { postgresVersion: '18.4', powaVersion: '5.2.0', sizeBytes: 32_000_000, retentionDays: 90 },
    }
    if (demoModeEnabled) return asResult(mapOperations(demoRaw, { available: true, items: [] }, { available: true, items: [], capabilities: [], contexts: [], servers: [] }), 'demo')

    const [raw, indexResult, ioResult] = await Promise.all([
      request<RawOperations>('/operations', { signal }),
      request<unknown>(`/indexes?window=${window}`, { signal }).then((payload) => ({ payload })).catch((error: unknown) => ({ error })),
      request<unknown>(`/io?window=${window}`, { signal }).then((payload) => ({ payload })).catch((error: unknown) => ({ error })),
    ])
    const indexPayload = 'payload' in indexResult ? indexResult.payload : undefined
    const ioPayload = 'payload' in ioResult ? ioResult.payload : undefined
    const indexError = 'error' in indexResult ? indexResult.error : undefined
    const ioError = 'error' in ioResult ? ioResult.error : undefined
    const indexRecord = indexPayload && typeof indexPayload === 'object' ? indexPayload as Record<string, unknown> : undefined
    const ioRecord = ioPayload && typeof ioPayload === 'object' ? ioPayload as Record<string, unknown> : undefined
    const indexSummary = indexRecord?.summary && typeof indexRecord.summary === 'object' ? indexRecord.summary as Record<string, unknown> : undefined
    const ioSummary = ioRecord?.summary && typeof ioRecord.summary === 'object' ? ioRecord.summary as Record<string, unknown> : undefined
    const indexes: OperationsData['indexes'] = {
      available: Boolean(indexPayload),
      message: indexPayload ? undefined : indexError instanceof Error ? indexError.message : 'Index telemetrisi alınamadı.',
      summary: indexSummary ? {
        indexesObserved: Number(recordValue(indexSummary, 'indexesObserved') || 0),
        candidateSignals: Number(recordValue(indexSummary, 'candidateSignals') || 0),
        totalSizeBytes: Number(recordValue(indexSummary, 'totalSizeBytes') || 0),
        noScanSizeBytes: Number(recordValue(indexSummary, 'noScanSizeBytes', 'unusedSizeBytes') || 0),
      } : undefined,
      items: mapIndexItems(indexPayload),
    }
    const io: OperationsData['io'] = {
      available: Boolean(ioPayload),
      message: ioPayload ? undefined : ioError instanceof Error ? ioError.message : 'I/O telemetrisi alınamadı.',
      summary: ioSummary ? {
        reads: Number(recordValue(ioSummary, 'reads') || 0), writes: Number(recordValue(ioSummary, 'writes') || 0),
        readBytes: Number(recordValue(ioSummary, 'readBytes') || 0), writeBytes: Number(recordValue(ioSummary, 'writeBytes') || 0),
        extendBytes: Number(recordValue(ioSummary, 'extendBytes') || 0), cacheHits: Number(recordValue(ioSummary, 'cacheHits') || 0),
        cacheHitPercent: optionalNumber(recordValue(ioSummary, 'cacheHitPercent')) ?? null,
        tempBytes: Number(recordValue(ioSummary, 'tempBytes') || 0), walBytes: Number(recordValue(ioSummary, 'walBytes') || 0),
        checkpoints: Number(recordValue(ioSummary, 'checkpoints') || 0), checkpointWriteTimeMs: Number(recordValue(ioSummary, 'checkpointWriteTimeMs') || 0),
        backendWrites: Number(recordValue(ioSummary, 'backendWrites') || 0),
      } : undefined,
      items: mapIoItems(ioPayload),
      capabilities: Array.isArray(ioRecord?.capabilities) ? ioRecord.capabilities
        .filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === 'object')
        .map((item) => ({
          key: String(recordValue(item, 'key') || 'unknown'),
          available: Boolean(recordValue(item, 'available')),
          resetEpochAware: Boolean(recordValue(item, 'resetEpochAware', 'reset_epoch_aware')),
          source: String(recordValue(item, 'source') || '—'),
          limitation: recordValue(item, 'limitation') == null ? null : String(recordValue(item, 'limitation')),
        })) : [],
      contexts: Array.isArray(ioRecord?.contexts) ? ioRecord.contexts as OperationsData['io']['contexts'] : [],
      servers: Array.isArray(ioRecord?.servers) ? ioRecord.servers as OperationsData['io']['servers'] : [],
    }
    return asResult(mapOperations(raw, indexes, io), 'api')
  },
}
