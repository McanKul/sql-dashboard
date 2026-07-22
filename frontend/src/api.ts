import { demoHealth, demoOverview, demoQueries, demoQueryDetails } from './demoData'
import type {
  ApiErrorShape,
  ApiList,
  ApiResult,
  OverviewStats,
  QueryDetail,
  QueryFinding,
  QuerySummary,
  Severity,
  SystemHealth,
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
  previousCalls: number
  previousMeanExecTimeMs: number
  regressionPercent: number
  impactScore: number
  priority: string
  status: string
  note?: string | null
  updatedBy?: string | null
  updatedAt?: string | null
  findings: string[]
  scoreBreakdown: Record<string, RawScorePart>
}

interface RawQueryDetail extends RawQuery {
  trend: Array<{ timestamp: string; totalExecTimeMs: number; calls: number }>
  comparison: {
    currentMeanMs: number
    previousMeanMs: number
    regressionPercent: number
    currentCalls: number
    previousCalls: number
  }
  recommendations?: { available: boolean; label: string; reason: string } | null
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
      'X-Advisor-Actor': 'advisor-web',
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
      ...init?.headers,
    },
  }).catch((cause: unknown) => {
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
  const sql = query.sql.trim()
  const verb = (sql.match(/^([a-z]+)/i)?.[1] || 'SQL').toUpperCase()
  const relation = sql.match(/\b(?:from|update|into|delete\s+from)\s+([\w."-]+)/i)?.[1]?.replaceAll('"', '')
  return relation ? `${verb} · ${relation}` : `${verb} sorgusu · ${query.databaseName}`
}

function mapSummary(query: RawQuery, observedAt = new Date().toISOString()): QuerySummary {
  const impactScore = clamp(Number(query.impactScore))
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
    calls: Number(query.calls || 0),
    avgDurationMs: Number(query.meanExecTimeMs || 0),
    totalTimeMs: Number(query.totalExecTimeMs || 0),
    impactScore: Math.round(impactScore),
    severity: severityFromPriority(query.priority),
    lastSeenAt: observedAt,
    changePercent: Number(query.regressionPercent || 0),
    hasComparison: comparisonAvailable(Number(query.previousCalls || 0)),
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

function mapDetail(query: RawQueryDetail): QueryDetail {
  const observedAt = query.trend.at(-1)?.timestamp || query.updatedAt || new Date().toISOString()
  const summary = mapSummary(query, observedAt)
  const breakdown = Object.entries(query.scoreBreakdown || {}).map(([key, part]) => {
    const maxContribution = Math.round(Number(part.weight || 0) * 100)
    return {
      key,
      label: scoreLabels[key]?.label || key,
      contribution: clamp(Number(part.contribution || 0), 0, maxContribution),
      maxContribution,
      hint: scoreLabels[key]?.hint || 'Ağırlıklı etki bileşeni',
    }
  })
  const previousTotal = Number(query.comparison?.previousMeanMs || 0) * Number(query.comparison?.previousCalls || 0)
  const currentTotal = Number(query.comparison?.currentMeanMs || 0) * Number(query.comparison?.currentCalls || 0)
  const regression = Number(query.comparison?.regressionPercent || 0)

  return {
    ...summary,
    fullSql: query.sql,
    firstSeenAt: query.trend[0]?.timestamp || observedAt,
    p95DurationMs: query.meanExecTimeMs,
    rowsPerCall: 0,
    sharedBlocksHit: Number(query.sharedBlocksHit || 0),
    sharedBlocksRead: Number(query.sharedBlocksRead || 0),
    trend: (query.trend || []).map((point) => ({
      label: labelForTimestamp(point.timestamp),
      durationMs: point.calls ? Number(point.totalExecTimeMs || 0) / point.calls : 0,
      impactScore: summary.impactScore,
    })),
    scoreBreakdown: breakdown,
    comparison: [
      { metric: 'Ort. çalışma süresi', before: Number(query.comparison?.previousMeanMs || 0), after: Number(query.comparison?.currentMeanMs || 0), unit: 'ms', improvementPercent: -regression },
      { metric: 'Çağrı', before: Number(query.comparison?.previousCalls || 0), after: Number(query.comparison?.currentCalls || 0), unit: 'adet', improvementPercent: query.comparison?.previousCalls ? ((query.comparison.previousCalls - query.comparison.currentCalls) / query.comparison.previousCalls) * 100 : 0 },
      { metric: 'Toplam çalışma', before: previousTotal, after: currentTotal, unit: 'ms', improvementPercent: previousTotal ? ((previousTotal - currentTotal) / previousTotal) * 100 : 0 },
    ],
    findings: mapFindings(query),
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

export const advisorApi = {
  async getOverview(signal?: AbortSignal): Promise<ApiResult<OverviewStats>> {
    if (demoModeEnabled) return asResult(demoOverview, 'demo')
    return asResult(mapOverview(await request<RawOverview>('/overview', { signal })), 'api')
  },

  async getQueries(signal?: AbortSignal): Promise<ApiResult<ApiList<QuerySummary>>> {
    if (demoModeEnabled) return asResult({ items: demoQueries, total: demoQueries.length }, 'demo')
    const payload = await request<{ items: RawQuery[]; total: number }>('/queries?pageSize=200&sort=impact', { signal })
    return asResult({ items: payload.items.map((query) => mapSummary(query)), total: payload.total }, 'api')
  },

  async getQuery(id: string, signal?: AbortSignal): Promise<ApiResult<QueryDetail>> {
    if (demoModeEnabled) {
      const detail = demoQueryDetails[id]
      if (!detail) throw new ApiClientError({ status: 404, path: `/queries/${id}`, message: 'Sorgu bulunamadı.' })
      return asResult(detail, 'demo')
    }
    const key = parseQueryKey(id)
    const params = new URLSearchParams()
    if (key.serverId !== undefined) params.set('serverId', String(key.serverId))
    if (key.databaseId !== undefined) params.set('databaseId', String(key.databaseId))
    const suffix = params.size ? `?${params.toString()}` : ''
    return asResult(mapDetail(await request<RawQueryDetail>(`/queries/${encodeURIComponent(key.queryId)}${suffix}`, { signal })), 'api')
  },

  async getSystemHealth(signal?: AbortSignal): Promise<ApiResult<SystemHealth>> {
    if (demoModeEnabled) return asResult(demoHealth, 'demo')
    return asResult(mapSystemHealth(await request<RawSystemHealth>('/system-health', { signal })), 'api')
  },
}
