import { lazy, Suspense, useEffect, useId, useMemo, useRef, useState } from 'react'
import {
  Activity,
  AlertCircle,
  AlertTriangle,
  ArrowDownRight,
  ArrowLeft,
  ArrowRight,
  ArrowUpRight,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  CircleDot,
  Clipboard,
  Clock3,
  Code2,
  Database,
  Gauge,
  HeartPulse,
  Info,
  LayoutDashboard,
  LoaderCircle,
  Menu,
  Network,
  RefreshCw,
  Search,
  ShieldAlert,
  Sparkles,
  X,
  Zap,
} from 'lucide-react'
import { advisorApi, ApiClientError, demoModeEnabled } from './api'
import type {
  ApiList,
  CompositeIndexCandidate,
  DatabaseOption,
  OperationsData,
  OverviewStats,
  PageId,
  QueryDetail,
  QueryBindValue,
  QueryExplainAnalyzeResult,
  QueryIndexAdvice,
  QueryListParams,
  QueryPredicate,
  QuerySummary,
  ServerOption,
  Severity,
  SystemHealth,
  TimeWindow,
  TrendPoint,
} from './types'
import {
  chartPoints,
  formatBytes,
  formatCacheHit,
  formatDateTime,
  formatDuration,
  formatLargeNumber,
  formatNumber,
  formatScoreContribution,
  formatVolumeFactor,
  scoreContributionLabel,
  scoreRelativeLabel,
  scoreVolumeLabel,
  severityLabels,
  windowLabels,
} from './utils'
import { ExplainPlanErrorBoundary } from './components/explain/ExplainPlanErrorBoundary'
import './styles.css'

const ExplainPlanGraph = lazy(async () => {
  const module = await import('./components/explain/ExplainPlanGraph')
  return { default: module.ExplainPlanGraph }
})

type LoadStatus = 'idle' | 'loading' | 'success' | 'error'
interface Loadable<T> {
  status: LoadStatus
  data?: T
  error?: string
}

const navItems: Array<{ id: PageId; label: string; description: string; icon: typeof LayoutDashboard }> = [
  { id: 'overview', label: 'Genel Bakış', description: 'Performans özeti', icon: LayoutDashboard },
  { id: 'queries', label: 'Sorgular', description: 'Analiz ve bulgular', icon: Code2 },
  { id: 'health', label: 'Sistem Sağlığı', description: 'PostgreSQL metrikleri', icon: HeartPulse },
  { id: 'operations', label: 'Operasyonlar', description: 'Repository ve telemetri', icon: Network },
]

const pageTitles: Record<PageId, string> = {
  overview: 'Genel Bakış',
  queries: 'Sorgu Analizi',
  health: 'Sistem Sağlığı',
  operations: 'Operasyonlar',
}

const getInitialPage = (): PageId => {
  const page = window.location.hash.replace('#/', '') as PageId
  return navItems.some((item) => item.id === page) ? page : 'overview'
}

function SeverityBadge({ severity, label }: { severity: Severity; label?: string }) {
  return <span className={`status-badge ${severity}`}><i aria-hidden="true" />{label ?? severityLabels[severity]}</span>
}

const queryImpactLabels: Record<Severity, string> = {
  critical: 'Öncelik çok yüksek',
  warning: 'İnceleme önceliği',
  healthy: 'Öncelik düşük',
}

function QueryImpactBadge({ severity }: { severity: Severity }) {
  return <SeverityBadge severity={severity} label={queryImpactLabels[severity]} />
}

function PageHeading({ eyebrow, title, description, children }: {
  eyebrow: string
  title: string
  description: string
  children?: React.ReactNode
}) {
  return (
    <div className="page-heading">
      <div>
        <span className="eyebrow">{eyebrow}</span>
        <h1>{title}</h1>
        <p>{description}</p>
      </div>
      {children && <div className="heading-actions">{children}</div>}
    </div>
  )
}

const timeWindows: TimeWindow[] = ['1h', '24h', '7d', '30d']

function WindowPicker({ value, onChange }: { value: TimeWindow; onChange: (window: TimeWindow) => void }) {
  return (
    <div className="window-picker" aria-label="Analiz zaman aralığı">
      <span>Zaman aralığı</span>
      <div>
        {timeWindows.map((window) => <button type="button" key={window} className={value === window ? 'active' : ''} onClick={() => onChange(window)} aria-pressed={value === window}>{window}</button>)}
      </div>
    </div>
  )
}

function LoadingPanel({ label = 'Veriler yükleniyor' }: { label?: string }) {
  return (
    <div className="loading-panel" role="status">
      <LoaderCircle className="spin" size={28} aria-hidden="true" />
      <strong>{label}</strong>
      <span>Advisor API yanıtı bekleniyor.</span>
    </div>
  )
}

function ErrorPanel({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div className="error-panel" role="alert">
      <span className="error-panel-icon"><ShieldAlert size={24} /></span>
      <div>
        <strong>Veri alınamadı</strong>
        <p>{message}</p>
        <small>API’nin <code>/api/v1</code> altında çalıştığını ve web proxy ayarını kontrol edin.</small>
      </div>
      <button type="button" className="secondary-button" onClick={onRetry}><RefreshCw size={15} /> Yeniden dene</button>
    </div>
  )
}

function ReadingGuide({ children }: { children: React.ReactNode }) {
  return (
    <aside className="reading-guide">
      <span><Info size={18} aria-hidden="true" /></span>
      <div><strong>Bu ekran ne anlatıyor?</strong><p>{children}</p></div>
    </aside>
  )
}

function MiniTrend({ points, tone = 'blue', height = 118, label }: {
  points: TrendPoint[]
  tone?: 'blue' | 'green' | 'orange' | 'red'
  height?: number
  label: string
}) {
  const gradientId = useId().replace(/:/g, '')
  const width = 380
  const polyline = chartPoints(points, width, height, 10)
  const area = polyline ? `10,${height - 5} ${polyline} ${width - 10},${height - 5}` : ''

  return (
    <div className={`mini-trend ${tone}`}>
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} preserveAspectRatio="none">
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="currentColor" stopOpacity=".2" />
            <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
          </linearGradient>
        </defs>
        <line x1="10" y1={height * .28} x2={width - 10} y2={height * .28} className="chart-guide" />
        <line x1="10" y1={height * .68} x2={width - 10} y2={height * .68} className="chart-guide" />
        <polygon points={area} fill={`url(#${gradientId})`} />
        <polyline points={polyline} className="chart-line" />
        {polyline && polyline.split(' ').map((point, index) => {
          const [cx, cy] = point.split(',')
          return <circle key={`${point}-${index}`} cx={cx} cy={cy} r={index === points.length - 1 ? 4 : 2.2} className="chart-dot" />
        })}
      </svg>
      <div className="chart-labels" aria-hidden="true">
        {points.map((point) => <span key={point.label}>{point.label}</span>)}
      </div>
    </div>
  )
}

function ImpactRing({ impact, severity, size = 'large' }: { impact: number; severity: Severity; size?: 'small' | 'large' }) {
  const safe = Math.max(0, Math.min(100, impact))
  return (
    <div className={`impact-ring ${size} ${severity}`} style={{ '--impact-angle': `${safe * 3.6}deg` } as React.CSSProperties} aria-label={`Etki puanı 100 üzerinden ${safe}`}>
      <div><strong>{safe}</strong>{size === 'large' && <span>/100</span>}</div>
    </div>
  )
}

function StatCard({ icon: Icon, label, value, unit, delta, tone, helper }: {
  icon: typeof Gauge
  label: string
  value: string
  unit?: string
  delta?: string
  tone: 'blue' | 'green' | 'orange' | 'red'
  helper: string
}) {
  return (
    <article className={`stat-card tone-${tone}`}>
      <div className="stat-card-top"><span className="metric-icon"><Icon size={19} /></span>{delta && <span className="metric-delta"><ArrowUpRight size={13} />{delta}</span>}</div>
      <div className="metric-value"><strong>{value}</strong>{unit && <span>{unit}</span>}</div>
      <h3>{label}</h3>
      <p>{helper}</p>
    </article>
  )
}

function OverviewPage({ state, queries, window, onRetry, onOpenQuery, onNavigate }: {
  state: Loadable<OverviewStats>
  queries?: ApiList<QuerySummary>
  window: TimeWindow
  onRetry: () => void
  onOpenQuery: (id: string) => void
  onNavigate: (page: PageId) => void
}) {
  if (state.status === 'loading' || state.status === 'idle') return <LoadingPanel label="Genel bakış hazırlanıyor" />
  if (state.status === 'error' || !state.data) return <ErrorPanel message={state.error ?? 'Bilinmeyen bir hata oluştu.'} onRetry={onRetry} />
  const data = state.data
  const queryPreview = queries?.items.slice(0, 4) ?? []

  return (
    <section className="page-section" aria-labelledby="overview-title">
      <PageHeading eyebrow={`${data.environment} · ${data.databaseName} · ${windowLabels[window]}`} title="Veritabanınız nasıl?" description={`Son toplama ${formatDateTime(data.lastCollectedAt)} tarihinde tamamlandı.`}>
        <button type="button" className="primary-button" onClick={() => onNavigate('queries')}><Sparkles size={16} /> Bulguları incele</button>
      </PageHeading>

      <ReadingGuide>Önce kritik sorgulara ve “En yüksek etkili sorgular” listesine bakın. Etki puanı yükseldikçe sorgunun toplam kaynak tüketimindeki önceliği artar; bu puan tek başına sorgunun hatalı olduğu anlamına gelmez.</ReadingGuide>

      <div className="stats-grid">
        <StatCard icon={Code2} label="Analiz edilen sorgu" value={formatNumber(data.queriesAnalyzed, true)} tone="blue" helper="Seçili dönemdeki benzersiz sorgu desenleri" />
        <StatCard icon={ArrowUpRight} label="Yavaşlayan sorgu" value={String(data.regressions)} tone="orange" helper="Önceki eş döneme göre süresi artan sorgular" />
        <StatCard icon={AlertCircle} label="Kritik sorgu" value={String(data.criticalQueries)} tone="red" helper="Önce incelenmesi gereken yüksek etkili sorgular" />
        <StatCard icon={Clock3} label="Toplam sorgu süresi" value={formatDuration(data.databaseTimeHours * 3_600_000)} tone="orange" helper="Tüm çağrıların ölçülen yürütme süreleri toplamı; CPU süresi değildir" />
      </div>

      <div className="dashboard-two-column">
        <article className="panel performance-panel">
          <div className="panel-heading">
            <div><span className="panel-kicker">Seçili pencere</span><h2>Ortalama sorgu çalışma süresi</h2></div>
            <div className="chart-summary"><strong>{formatDuration(data.latencyTrend.at(-1)?.value ?? 0)}</strong><span><Activity size={14} /> PoWA zaman serisi</span></div>
          </div>
          <MiniTrend points={data.latencyTrend} tone="blue" height={154} label="Seçili zaman aralığında ortalama sorgu çalışma süresi" />
        </article>

        <article className="panel opportunity-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Öncelikli liste</span><h2>En yüksek etkili sorgular</h2></div><Zap size={20} className="panel-accent-icon" /></div>
          <div className="opportunity-list">
            {data.opportunities.map((opportunity, index) => (
              <button type="button" key={opportunity.queryId} onClick={() => onOpenQuery(opportunity.queryId)}>
                <span className="opportunity-rank">0{index + 1}</span>
                <span className="opportunity-copy"><strong>{opportunity.title}</strong><small>Ölçülen sorgu süresindeki pay %{formatNumber(opportunity.loadPercent)}</small></span>
                <span className="saving-value">{formatDuration(opportunity.averageMs)}<ChevronRight size={15} /></span>
              </button>
            ))}
          </div>
        </article>
      </div>

      <div className="dashboard-lower-grid">
        <article className="panel query-preview-panel">
          <div className="panel-heading">
            <div><span className="panel-kicker">Canlı önceliklendirme</span><h2>İlgilenmeniz gereken sorgular</h2></div>
            <button type="button" className="text-button" onClick={() => onNavigate('queries')}>Tümünü gör <ArrowRight size={15} /></button>
          </div>
          {queryPreview.length ? (
            <div className="compact-query-list">
              {queryPreview.map((query) => (
                <button type="button" key={query.id} onClick={() => onOpenQuery(query.id)}>
                  <ImpactRing impact={query.impactScore} severity={query.severity} size="small" />
                  <span className="compact-query-copy"><strong>{query.title}</strong><code>{query.fingerprint}</code></span>
                  <span className="query-duration">{formatDuration(query.avgDurationMs)}<small>ortalama</small></span>
                  {query.hasComparison
                    ? <span className={`change ${regressionValue(query) > 0 ? 'negative' : 'positive'}`}>{regressionValue(query) > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />}%{formatNumber(Math.abs(regressionValue(query)))}</span>
                    : <span className="change unavailable">{comparisonStatusLabel(query)}</span>}
                  <ChevronRight size={16} className="row-chevron" />
                </button>
              ))}
            </div>
          ) : <div className="empty-inline">Sorgu listesi henüz hazır değil.</div>}
        </article>

        <article className="panel activity-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Seçili pencere</span><h2>Son snapshot özeti</h2></div><Activity size={19} className="panel-accent-icon" /></div>
          <div className="activity-list">
            {data.recentActivity.map((activity) => (
              <div key={activity.id} className="activity-item">
                <span className={`activity-dot ${activity.tone}`}><i /></span>
                <div><strong>{activity.title}</strong><p>{activity.detail}</p><time dateTime={activity.occurredAt}>{formatDateTime(activity.occurredAt)}</time></div>
              </div>
            ))}
          </div>
        </article>
      </div>
    </section>
  )
}

function QueriesPage({ state, params, window, onParamsChange, onRetry, onOpenQuery }: {
  state: Loadable<ApiList<QuerySummary>>
  params: QueryListParams
  window: TimeWindow
  onParamsChange: (params: QueryListParams) => void
  onRetry: () => void
  onOpenQuery: (id: string) => void
}) {
  const [draft, setDraft] = useState<QueryListParams>(params)
  const [servers, setServers] = useState<ServerOption[]>([])
  const [databases, setDatabases] = useState<DatabaseOption[]>([])

  useEffect(() => {
    const controller = new AbortController()
    Promise.all([advisorApi.getServers(controller.signal), advisorApi.getDatabases(undefined, controller.signal)])
      .then(([serverResult, databaseResult]) => { setServers(serverResult.data); setDatabases(databaseResult.data) })
      .catch(() => { /* Filtre meta verisi yoksa sorgu listesi kullanılmaya devam eder. */ })
    return () => controller.abort()
  }, [])

  useEffect(() => setDraft(params), [params])

  const filteredDatabases = draft.serverId === undefined ? databases : databases.filter((database) => database.serverId === draft.serverId)
  const selectedDatabaseKey = draft.serverId !== undefined && draft.databaseId !== undefined ? `${draft.serverId}:${draft.databaseId}` : ''
  const selectDatabase = (key: string) => {
    if (!key) {
      setDraft((value) => ({ ...value, databaseId: undefined }))
      return
    }
    const [serverId, databaseId] = key.split(':').map(Number)
    setDraft((value) => ({ ...value, serverId, databaseId }))
  }
  const hasFilters = Boolean(params.search || params.priority || params.serverId !== undefined || params.databaseId !== undefined || params.minCalls || params.minDurationMs)
  const totalPages = Math.max(1, Math.ceil((state.data?.total || 0) / params.pageSize))
  const applyFilters = () => onParamsChange({ ...draft, page: 1 })
  const clearFilters = () => {
    const cleared: QueryListParams = { page: 1, pageSize: params.pageSize, sort: 'impact' }
    setDraft(cleared)
    onParamsChange(cleared)
  }

  return (
    <section className="page-section" aria-labelledby="queries-title">
      <PageHeading eyebrow={`Sorgu envanteri · ${windowLabels[window]}`} title="Etkiyi bulun, nedeni anlayın" description={`${formatNumber(state.data?.total || 0)} benzersiz sorgu; repository telemetrisiyle sunucu tarafında filtrelenir.`} />

      <ReadingGuide>Etki puanı seçili penceredeki diğer sorgulara göre inceleme önceliğini gösterir. DB yükü, gerçek CPU ve sampled wait dağılımını birlikte okuyun; CPU süresi ile wait örnekleri aynı paydada toplanmaz.</ReadingGuide>

      <div className="query-toolbar query-toolbar-expanded" role="search" onKeyDown={(event) => { if (event.key === 'Enter' && (event.target as HTMLElement).tagName === 'INPUT') applyFilters() }}>
        <label className="search-field"><Search size={18} aria-hidden="true" /><span className="sr-only">Sorgularda ara</span><input value={draft.search || ''} onChange={(event) => setDraft((value) => ({ ...value, search: event.target.value || undefined }))} placeholder="SQL veya sorgu kimliği ara…" /></label>
        <label className="select-field"><Network size={15} /><span className="sr-only">Sunucu</span><select value={draft.serverId ?? ''} onChange={(event) => setDraft((value) => ({ ...value, serverId: event.target.value ? Number(event.target.value) : undefined, databaseId: undefined }))}><option value="">Tüm sunucular</option>{servers.map((server) => <option key={server.id} value={server.id}>{server.alias || server.hostname || `server-${server.id}`}</option>)}</select><ChevronDown size={14} /></label>
        <label className="select-field"><Database size={15} /><span className="sr-only">Veritabanı</span><select value={selectedDatabaseKey} onChange={(event) => selectDatabase(event.target.value)}><option value="">Tüm veritabanları</option>{filteredDatabases.map((database) => <option key={`${database.serverId}:${database.databaseId}`} value={`${database.serverId}:${database.databaseId}`}>{database.name}{draft.serverId === undefined ? ` · ${servers.find((server) => server.id === database.serverId)?.alias || `server-${database.serverId}`}` : ''}</option>)}</select><ChevronDown size={14} /></label>
        <label className="select-field"><CircleDot size={15} /><span className="sr-only">Öncelik</span><select value={draft.priority || ''} onChange={(event) => setDraft((value) => ({ ...value, priority: event.target.value || undefined }))}><option value="">Tüm öncelikler</option><option value="CRITICAL">Kritik</option><option value="HIGH">Yüksek</option><option value="MEDIUM">Orta</option><option value="LOW">Düşük</option></select><ChevronDown size={14} /></label>
        <label className="number-field"><span>Min. çağrı</span><input type="number" min="0" value={draft.minCalls ?? ''} onChange={(event) => setDraft((value) => ({ ...value, minCalls: event.target.value ? Number(event.target.value) : undefined }))} /></label>
        <label className="number-field"><span>Min. toplam süre</span><input type="number" min="0" step="10" value={draft.minDurationMs ?? ''} onChange={(event) => setDraft((value) => ({ ...value, minDurationMs: event.target.value ? Number(event.target.value) : undefined }))} /><small>ms</small></label>
        <label className="select-field sort-field"><span>Sırala:</span><select value={draft.sort || 'impact'} onChange={(event) => setDraft((value) => ({ ...value, sort: event.target.value as QueryListParams['sort'] }))}><option value="impact">Etki</option><option value="totalTime">Toplam süre</option><option value="meanTime">Ortalama süre</option><option value="cpu">Gerçek CPU</option><option value="waits">Wait örneği</option><option value="calls">Çağrı</option><option value="reads">Fiziksel okuma</option><option value="regression">Regresyon</option></select><ChevronDown size={14} /></label>
        <button type="button" className="primary-button filter-button" onClick={applyFilters}>Uygula</button>
      </div>

      <div className="query-results-summary"><span><b>{state.data?.items.length || 0}</b> satır · toplam <b>{formatNumber(state.data?.total || 0)}</b> sonuç · sayfa {params.page}/{totalPages}</span>{hasFilters && <button type="button" onClick={clearFilters}>Filtreleri temizle <X size={13} /></button>}</div>

      {state.status === 'loading' || state.status === 'idle' ? <LoadingPanel label="Sorgular analiz ediliyor" /> : state.status === 'error' || !state.data ? <ErrorPanel message={state.error ?? 'Sorgu listesi alınamadı.'} onRetry={onRetry} /> : <>
        <div className="query-table-card">
          <table className="query-table query-metrics-table">
            <caption className="sr-only">Analiz edilen PostgreSQL sorguları ve ham performans metrikleri</caption>
            <thead><tr><th scope="col">Sorgu</th><th scope="col">İnceleme puanı</th><th scope="col">DB yükü</th><th scope="col">Çalışma süresi</th><th scope="col">Gerçek CPU</th><th scope="col">Baskın wait</th><th scope="col">Shared blok</th><th scope="col">Temp / WAL</th><th scope="col">Çağrı / regresyon</th><th scope="col"><span className="sr-only">Aç</span></th></tr></thead>
            <tbody>
              {state.data.items.map((query) => (
                <tr key={query.id} onClick={() => onOpenQuery(query.id)}>
                  <td><button type="button" className="query-name-button" onClick={() => onOpenQuery(query.id)}><span><strong>{query.title}</strong><code>{query.sqlPreview}</code></span><small>{query.database} · {query.fingerprint}</small></button></td>
                  <td><div className="table-score"><ImpactRing impact={query.impactScore} severity={query.severity} size="small" /><QueryImpactBadge severity={query.severity} /></div></td>
                  <td><strong className="tabular">%{formatNumber(query.dbLoadPercent)}</strong><small>ölçülen DB zamanı</small></td>
                  <td><strong className="tabular">{formatDuration(query.totalTimeMs)}</strong><small>{formatDuration(query.avgDurationMs)} ortalama</small></td>
                  <td>{query.cpu.capability.dataAvailable && query.cpu.totalTimeMs !== null
                    ? <><strong className="tabular">{formatDuration(query.cpu.totalTimeMs)}</strong><small>%{formatNumber(query.cpu.percentOfExecTime ?? 0)} DB süresi</small></>
                    : <><strong>—</strong><small>{query.cpu.capability.available ? 'veri birikiyor' : 'kcache kapalı'}</small></>}</td>
                  <td>{query.waits.capability.dataAvailable
                    ? query.waits.dominant
                      ? <><strong>{query.waits.dominant.category}</strong><small>{query.waits.dominant.event} · %{formatNumber(query.waits.dominant.sharePercent)}</small></>
                      : <><strong>Wait yok</strong><small>{formatLargeNumber(query.waits.totalSamples ?? 0)} örnek</small></>
                    : <><strong>—</strong><small>{query.waits.capability.available ? 'veri birikiyor' : 'waits kapalı'}</small></>}</td>
                  <td><strong className="tabular">{formatLargeNumber(query.sharedBlocksRead)} okuma</strong><small>{formatLargeNumber(query.sharedBlocksHit)} cache hit</small></td>
                  <td><strong className="tabular">{formatLargeNumber(query.tempBlocksWritten)} temp blok</strong><small>{formatBytes(query.walBytes)} WAL</small></td>
                  <td><strong className="tabular">{formatLargeNumber(query.calls)} çağrı</strong>{query.hasComparison
                    ? <span className={`change ${regressionValue(query) > 0 ? 'negative' : 'positive'}`}>{regressionValue(query) > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />}%{formatNumber(Math.abs(regressionValue(query)))}</span>
                    : <small>{comparisonStatusLabel(query)}</small>}
                  </td>
                  <td><button type="button" className="icon-button row-open" onClick={() => onOpenQuery(query.id)} aria-label={`${query.title} detayını aç`}><ChevronRight size={17} /></button></td>
                </tr>
              ))}
            </tbody>
          </table>
          {!state.data.items.length && <div className="empty-state"><Search size={28} /><strong>Eşleşen sorgu yok</strong><p>Arama ifadesini veya filtreleri değiştirin.</p></div>}
        </div>
        {state.data.total > params.pageSize && <div className="pagination"><button type="button" className="secondary-button" disabled={params.page <= 1} onClick={() => onParamsChange({ ...params, page: params.page - 1 })}><ArrowLeft size={15} /> Önceki</button><span>{params.page}. sayfa · {totalPages} sayfa</span><button type="button" className="secondary-button" disabled={params.page >= totalPages} onClick={() => onParamsChange({ ...params, page: params.page + 1 })}>Sonraki <ArrowRight size={15} /></button></div>}
      </>}
    </section>
  )
}

function scoreMetricValue(item: QueryDetail['scoreBreakdown'][number], query: QueryDetail): string {
  if (item.key === 'regression' && !query.hasComparison) return 'Karşılaştırma yok'
  let value = item.absoluteValue
  let unit = item.unit || ''
  if (value === undefined) {
    const fallback: Record<string, [number, string]> = {
      totalTime: [query.totalTimeMs, 'ms'], physicalRead: [query.sharedBlocksRead, 'blocks'],
      callFrequency: [query.calls, 'calls'], tempWrite: [query.tempBlocksWritten, 'blocks'],
      regression: [regressionValue(query), 'percent'], wal: [query.walBytes, 'bytes'],
    }
    ;[value, unit] = fallback[item.key] || [0, '']
  }
  if (unit.toLowerCase().includes('byte')) return formatBytes(value)
  if (unit.toLowerCase().includes('ms')) return formatDuration(value)
  if (unit.toLowerCase().includes('percent') || unit === '%') return `%${formatNumber(value)}`
  if (unit.toLowerCase().includes('block')) return `${formatLargeNumber(value)} blok`
  if (unit.toLowerCase().includes('call')) return `${formatLargeNumber(value)} çağrı`
  return `${formatLargeNumber(value)}${unit ? ` ${unit}` : ''}`
}

function regressionValue(query: Pick<QuerySummary, 'changePercent'>): number {
  return query.changePercent ?? 0
}

function comparisonStatusLabel(query: Pick<QuerySummary, 'resetDetected' | 'warmingUp' | 'previousPeriodAvailable' | 'comparisonReliable'>): string {
  if (query.resetDetected) return 'Sayaç reseti algılandı'
  if (query.warmingUp) return 'Veri birikiyor'
  if (!query.previousPeriodAvailable) return 'Önceki dönem yok'
  if (!query.comparisonReliable) return 'Karşılaştırma güvenilir değil'
  return 'En az 20 çağrı gerekli'
}

function comparisonStatusDetail(query: QuerySummary): string {
  if (query.resetDetected) return 'Seçili dönem içinde sayaç reseti bulunduğu için regresyon yüzdesi hesaplanmadı.'
  if (query.warmingUp) return 'İstenen pencereyi güvenilir biçimde karşılamak için collector geçmişi henüz birikiyor.'
  if (!query.previousPeriodAvailable) return 'Aynı sorgu için önceki eş dönemde karşılaştırılabilir ölçüm bulunamadı.'
  if (!query.comparisonReliable) {
    const coverage = query.coveragePercent === null ? '' : ` Ölçülen kapsam: %${formatNumber(query.coveragePercent)}.`
    return `Snapshot kapsamı veya collector sürekliliği güvenilir bir karşılaştırma için yeterli değil.${coverage}`
  }
  return 'Regresyon göstermek için mevcut ve önceki dönemde en az 20 çağrı gerekir.'
}

function scoreThresholdValue(item: QueryDetail['scoreBreakdown'][number]): string | null {
  if (item.fullScoreAt === undefined) return null
  const unit = item.unit || ''
  if (unit.toLowerCase().includes('byte')) return formatBytes(item.fullScoreAt)
  if (unit.toLowerCase().includes('ms')) return formatDuration(item.fullScoreAt)
  if (unit.toLowerCase().includes('percent') || unit === '%') return `%${formatNumber(item.fullScoreAt)}`
  if (unit.toLowerCase().includes('block')) return `${formatLargeNumber(item.fullScoreAt)} blok`
  if (unit.toLowerCase().includes('call')) return `${formatLargeNumber(item.fullScoreAt)} çağrı`
  return `${formatLargeNumber(item.fullScoreAt)}${unit ? ` ${unit}` : ''}`
}

function predicateSignalLabel(signal: QueryDetail['predicates']['items'][number]['signal']): string {
  const labels = {
    INDEX_CANDIDATE: 'Index adayı gözlemi',
    REVIEW: 'Planla birlikte incele',
    INDEX_CONDITION_OBSERVED: 'Index koşulu gözlendi',
    OBSERVED: 'Filtre gözlendi',
    INSUFFICIENT_DATA: 'Yetersiz örnek',
  }
  return labels[signal]
}

function predicateSignalSeverity(signal: QueryDetail['predicates']['items'][number]['signal']): Severity {
  return signal === 'INDEX_CANDIDATE' || signal === 'REVIEW' || signal === 'INSUFFICIENT_DATA'
    ? 'warning'
    : 'healthy'
}

function predicateAdviceKey(predicate: QueryPredicate): string {
  return `${predicate.qualId}:${predicate.relationId}:${predicate.evalType}`
}

function indexAdviceLabel(status: QueryIndexAdvice['status']): string {
  return {
    VALIDATED: 'HypoPG doğruladı',
    NO_IMPROVEMENT: 'Plan iyileşmedi',
    UNAVAILABLE: 'Doğrulama kullanılamıyor',
    UNSAFE: 'Güvenle planlanamadı',
    INSUFFICIENT: 'Daha fazla örnek gerekli',
  }[status]
}

function PredicateIndexEvaluation({
  predicate,
  state,
  copied,
  onEvaluate,
  onCopy,
}: {
  predicate: QueryPredicate
  state?: Loadable<QueryIndexAdvice>
  copied: boolean
  onEvaluate: () => void
  onCopy: (statement: string) => void
}) {
  const eligible = predicate.evalType === 'FILTER'
    && (predicate.signal === 'INDEX_CANDIDATE' || predicate.signal === 'REVIEW')
    && predicate.schemaName !== 'unknown'
    && predicate.columns.length === 1
  if (!eligible) return null

  const advice = state?.data
  return (
    <div className="index-evaluation" aria-live="polite">
      {!state && (
        <div className="index-evaluation-start">
          <div><strong>Gerçek SQL önerisi henüz doğrulanmadı</strong><span>HypoPG kaynakta sanal index kurup yalnız EXPLAIN maliyetini karşılaştırır.</span></div>
          <button type="button" className="hypopg-button" onClick={onEvaluate}><Sparkles size={15} /> HypoPG ile doğrula</button>
        </div>
      )}
      {state?.status === 'loading' && <div className="index-evaluation-loading"><LoaderCircle className="spin" size={17} /> Baseline ve sanal index planları karşılaştırılıyor…</div>}
      {state?.status === 'error' && <div className="index-evaluation-error"><AlertCircle size={17} /><span>{state.error}</span><button type="button" onClick={onEvaluate}>Tekrar dene</button></div>}
      {state?.status === 'success' && advice && (
        <div className={`index-evaluation-result ${advice.status.toLowerCase()}`}>
          <div className="index-evaluation-status">
            {advice.status === 'VALIDATED' ? <CheckCircle2 size={18} /> : <Info size={18} />}
            <div><strong>{indexAdviceLabel(advice.status)}</strong><span>{advice.message}</span></div>
          </div>
          {advice.status === 'VALIDATED' && advice.validation && advice.candidate && (
            <>
              <div className="index-plan-metrics">
                <div><span>Başlangıç maliyeti</span><strong>{formatNumber(advice.validation.baselineTotalCost)}</strong><small>{advice.validation.baselineAccess || 'Plan düğümü'}</small></div>
                <div><span>Sanal index maliyeti</span><strong>{formatNumber(advice.validation.hypotheticalTotalCost)}</strong><small>{advice.validation.hypotheticalAccess || 'Plan düğümü'}</small></div>
                <div><span>Tahmini düşüş</span><strong>%{formatNumber(advice.validation.costReductionPercent)}</strong><small>Planner cost, süre değil</small></div>
                <div><span>Tahmini index boyutu</span><strong>{formatBytes(advice.validation.estimatedIndexSizeBytes)}</strong><small>HypoPG {advice.validation.hypopgVersion}</small></div>
              </div>
              <div className="index-sql-heading"><div><strong>Kopyalanabilir index SQL’i</strong><span>İncelemeden çalıştırmayın; uygulama bu DDL’i yürütmedi.</span></div><button type="button" className="copy-sql-button" onClick={() => onCopy(advice.candidate!.createIndexSql)}>{copied ? <Check size={15} /> : <Clipboard size={15} />}{copied ? 'Kopyalandı' : 'Index SQL’ini kopyala'}</button></div>
              <pre className="index-sql"><code>{advice.candidate.createIndexSql}</code></pre>
              <div className="index-confidence"><span>{advice.confidence?.level === 'HIGH' ? 'Yüksek' : 'Orta'} güven</span>{advice.confidence?.reasons.map((reason) => <small key={reason}>{reason}</small>)}</div>
            </>
          )}
          <small className="ddl-safety-note"><ShieldAlert size={13} /> ddlExecuted=false · Gerçek index oluşturulmadı</small>
        </div>
      )}
    </div>
  )
}

function compositeOrderingLabel(rule: CompositeIndexCandidate['orderingRule']): string {
  return {
    SELECTIVE_EQUALITY_FILTER_THEN_JOIN: 'Seçici eşitlik filtresi → JOIN kolonu',
    EQUALITY_JOIN_THEN_FILTER: 'JOIN kolonu → eşitlik filtresi',
    EQUALITY_JOIN_THEN_RANGE_FILTER: 'JOIN kolonu → range filtresi',
  }[rule]
}

export function CompositeIndexEvaluation({
  candidate,
  state,
  copied,
  onEvaluate,
  onCopy,
}: {
  candidate: CompositeIndexCandidate
  state?: Loadable<QueryIndexAdvice>
  copied: boolean
  onEvaluate: () => void
  onCopy: (statement: string) => void
}) {
  const advice = state?.data
  return (
    <div className="predicate-item review composite-candidate">
      <div className="predicate-item-heading">
        <div><strong>{candidate.schemaName}.{candidate.tableName}</strong><span>{candidate.columns.join(' → ')}</span></div>
        <SeverityBadge severity={candidate.confidence === 'HIGH' ? 'healthy' : 'warning'} label={`${candidate.confidence === 'HIGH' ? 'Yüksek' : 'Orta'} kanıt`} />
      </div>
      <div className="predicate-metrics">
        <div><span>JOIN gözlemi</span><strong>{formatLargeNumber(candidate.joinOccurrences)}</strong></div>
        <div><span>WHERE gözlemi</span><strong>{formatLargeNumber(candidate.filterOccurrences)}</strong></div>
        <div><span>Eleme oranı</span><strong>{candidate.filterRatio == null ? '—' : `%${formatNumber(candidate.filterRatio * 100)}`}</strong></div>
        <div><span>Snapshot</span><strong>{formatLargeNumber(candidate.sampleCount)}</strong></div>
      </div>
      <div className="predicate-recommendation"><Network size={16} /><div><strong>Kolon sırası</strong><span>{compositeOrderingLabel(candidate.orderingRule)}</span></div></div>
      {!state && <div className="index-evaluation-start"><div><strong>Önce canlı katalog + HypoPG kontrolü</strong><span>Mevcut index prefix’i ve planner maliyeti salt-okunur doğrulanır.</span></div><button type="button" className="hypopg-button" onClick={onEvaluate}><Sparkles size={15} /> Composite adayı doğrula</button></div>}
      {state?.status === 'loading' && <div className="index-evaluation-loading"><LoaderCircle className="spin" size={17} /> Composite baseline ve sanal plan karşılaştırılıyor…</div>}
      {state?.status === 'error' && <div className="index-evaluation-error"><AlertCircle size={17} /><span>{state.error}</span><button type="button" onClick={onEvaluate}>Tekrar dene</button></div>}
      {state?.status === 'success' && advice && <div className={`index-evaluation-result ${advice.status.toLowerCase()}`}>
        <div className="index-evaluation-status">{advice.status === 'VALIDATED' ? <CheckCircle2 size={18} /> : <Info size={18} />}<div><strong>{indexAdviceLabel(advice.status)}</strong><span>{advice.message}</span></div></div>
        {advice.validation && <div className="index-plan-metrics"><div><span>Başlangıç cost</span><strong>{formatNumber(advice.validation.baselineTotalCost)}</strong></div><div><span>Composite cost</span><strong>{formatNumber(advice.validation.hypotheticalTotalCost)}</strong></div><div><span>Tahmini düşüş</span><strong>%{formatNumber(advice.validation.costReductionPercent)}</strong></div><div><span>Tahmini boyut</span><strong>{formatBytes(advice.validation.estimatedIndexSizeBytes)}</strong></div></div>}
        {advice.status === 'VALIDATED' && advice.candidate && <><div className="index-sql-heading"><div><strong>Kopyalanabilir composite SQL</strong><span>Uygulama kaynakta DDL çalıştırmadı.</span></div><button type="button" className="copy-sql-button" onClick={() => onCopy(advice.candidate!.createIndexSql)}>{copied ? <Check size={15} /> : <Clipboard size={15} />}{copied ? 'Kopyalandı' : 'SQL’i kopyala'}</button></div><pre className="index-sql"><code>{advice.candidate.createIndexSql}</code></pre></>}
        <small className="ddl-safety-note"><ShieldAlert size={13} /> ddlExecuted=false</small>
      </div>}
      {advice?.status === 'VALIDATED' && (candidate.runtimeFixtureAvailable
        ? <div className="index-evaluation-start runtime-validation-start"><div><strong>Operator doğrulamasına hazır</strong><span>Replay fixture onaylı. Browser admin secret’ı taşımaz; disposable clone testi yalnız server-side token kullanan operator API/CLI akışından başlatılır.</span></div><button type="button" className="hypopg-button" disabled><ShieldAlert size={15} /> Operator API</button></div>
        : <div className="index-evaluation-start runtime-validation-start"><div><strong>Replay fixture gerekli</strong><span>Normalize bind değerleri saklanmaz. DBA bu sorgu ve aday için sentetik/anonymize fixture onayladığında operator API akışı açılır.</span></div><button type="button" className="hypopg-button" disabled><ShieldAlert size={15} /> Fixture yok</button></div>)}
    </div>
  )
}

export function highestBindParameter(statement: string): number {
  let highest = 0
  let index = 0
  let blockCommentDepth = 0
  let mode: 'normal' | 'single' | 'escape-single' | 'double' | 'line-comment' | 'block-comment' | 'dollar' = 'normal'
  let dollarTag = ''

  while (index < statement.length) {
    const current = statement[index]
    const next = statement[index + 1]
    if (mode === 'line-comment') {
      if (current === '\n' || current === '\r') mode = 'normal'
      index += 1
      continue
    }
    if (mode === 'block-comment') {
      if (current === '/' && next === '*') { blockCommentDepth += 1; index += 2; continue }
      if (current === '*' && next === '/') {
        blockCommentDepth -= 1
        index += 2
        if (blockCommentDepth === 0) mode = 'normal'
        continue
      }
      index += 1
      continue
    }
    if (mode === 'single') {
      if (current === "'" && next === "'") { index += 2; continue }
      if (current === "'") mode = 'normal'
      index += 1
      continue
    }
    if (mode === 'escape-single') {
      if (current === '\\') { index += 2; continue }
      if (current === "'" && next === "'") { index += 2; continue }
      if (current === "'") mode = 'normal'
      index += 1
      continue
    }
    if (mode === 'double') {
      if (current === '"' && next === '"') { index += 2; continue }
      if (current === '"') mode = 'normal'
      index += 1
      continue
    }
    if (mode === 'dollar') {
      if (statement.startsWith(dollarTag, index)) {
        index += dollarTag.length
        mode = 'normal'
      } else index += 1
      continue
    }
    if (current === '-' && next === '-') { mode = 'line-comment'; index += 2; continue }
    if (current === '/' && next === '*') { mode = 'block-comment'; blockCommentDepth = 1; index += 2; continue }
    if (current === "'") {
      const prefix = statement[index - 1]
      const beforePrefix = statement[index - 2]
      const escapePrefixed = (prefix === 'E' || prefix === 'e')
        && (index < 2 || !/[A-Za-z0-9_$]/.test(beforePrefix))
      mode = escapePrefixed ? 'escape-single' : 'single'
      index += 1
      continue
    }
    if (current === '"') { mode = 'double'; index += 1; continue }
    if (current === '$') {
      const parameter = statement.slice(index).match(/^\$([1-9][0-9]*)/)
      if (parameter) {
        highest = Math.max(highest, Number(parameter[1]))
        index += parameter[0].length
        continue
      }
      const delimiter = statement.slice(index).match(/^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/)?.[0]
      if (delimiter) {
        dollarTag = delimiter
        mode = 'dollar'
        index += delimiter.length
        continue
      }
    }
    index += 1
  }
  return highest
}

const SOURCE_EXPLAIN_MAX_BIND_VALUES = 128
const SOURCE_EXPLAIN_MAX_BIND_BYTES = 64 * 1024

export function parseExplainBindValues(input: string, requiredCount: number): { values: QueryBindValue[] } | { error: string } {
  if (requiredCount === 0) return { values: [] }
  if (requiredCount > SOURCE_EXPLAIN_MAX_BIND_VALUES) return { error: `Bu sorgu ${requiredCount} bind değeri istiyor; kaynak EXPLAIN sınırı ${SOURCE_EXPLAIN_MAX_BIND_VALUES}.` }
  let parsed: unknown
  try {
    parsed = JSON.parse(input)
  } catch {
    return { error: 'Bind değerlerini geçerli bir JSON array olarak girin.' }
  }
  if (!Array.isArray(parsed)) return { error: 'Bind değerleri bir JSON array olmalı.' }
  if (parsed.length > SOURCE_EXPLAIN_MAX_BIND_VALUES) return { error: `En fazla ${SOURCE_EXPLAIN_MAX_BIND_VALUES} bind değeri gönderebilirsiniz.` }
  if (parsed.length !== requiredCount) return { error: `Bu sorgu $1–$${requiredCount} için tam ${requiredCount} değer istiyor.` }
  const scalarValues: QueryBindValue[] = []
  for (const value of parsed) {
    if (value !== null && typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean') {
      return { error: 'Her bind değeri string, number, boolean veya null olmalı.' }
    }
    if (typeof value === 'number' && !Number.isFinite(value)) return { error: 'Sayısal bind değerleri sonlu olmalı.' }
    if (typeof value === 'number' && Number.isInteger(value) && !Number.isSafeInteger(value)) {
      return { error: 'JavaScript güvenli integer sınırını aşan değerleri hassasiyet kaybını önlemek için JSON string olarak girin.' }
    }
    if (typeof value === 'string' && value.length > 2_048) return { error: 'Bir bind string değeri en fazla 2048 karakter olabilir.' }
    scalarValues.push(value as QueryBindValue)
  }
  if (new TextEncoder().encode(JSON.stringify(scalarValues)).length > SOURCE_EXPLAIN_MAX_BIND_BYTES) return { error: 'Bind değerlerinin toplam boyutu 64 KiB sınırını aşıyor.' }
  return { values: scalarValues }
}

function explainStatusLabel(status: QueryExplainAnalyzeResult['status']): string {
  return {
    RUNTIME_VALIDATED: 'EXPLAIN ANALYZE tamamlandı',
    UNAVAILABLE: 'Kaynak doğrulaması kullanılamıyor',
    UNSAFE: 'Sorgu güvenlik kapısından geçmedi',
  }[status]
}

function ExplainRawPlan({ plan, evaluatedAt }: { plan: Record<string, unknown>; evaluatedAt: string }) {
  const [expanded, setExpanded] = useState(false)
  const formattedPlan = useMemo(() => expanded ? JSON.stringify(plan, null, 2) : '', [expanded, plan])
  return (
    <details className="explain-plan-details" onToggle={(event) => setExpanded(event.currentTarget.open)}>
      <summary className="explain-plan-heading"><strong>Ham JSON planı</strong><span>{formatDateTime(evaluatedAt)} · {expanded ? 'Gizle' : 'Görüntüle'}</span></summary>
      {expanded && <pre className="explain-plan"><code>{formattedPlan}</code></pre>}
    </details>
  )
}

function ExplainExecutionAttestation({ result }: { result: QueryExplainAnalyzeResult }) {
  const sourceFact = result.sourceExecuted === null
    ? <span className="pending"><Clock3 size={13} /> Kaynak yürütme durumu doğrulanamadı</span>
    : result.sourceExecuted
      ? <span><Check size={13} /> Kaynak sorgu çalıştırıldı</span>
      : <span className="neutral"><CircleDot size={13} /> Kaynak sorgu çalıştırılmadı</span>

  let rollbackFact
  if (result.transactionRolledBack === null || (result.transactionRolledBack === false && result.sourceExecuted === null)) {
    rollbackFact = <span className="pending"><Clock3 size={13} /> Rollback durumu doğrulanamadı</span>
  } else if (result.transactionRolledBack) {
    rollbackFact = <span><Check size={13} /> Transaction geri alındı</span>
  } else if (result.sourceExecuted === false) {
    rollbackFact = <span className="neutral"><CircleDot size={13} /> Rollback gerekmedi</span>
  } else {
    rollbackFact = <span className="warning"><AlertCircle size={13} /> Rollback başarısız</span>
  }

  return <>{sourceFact}{rollbackFact}</>
}

export function ExplainAnalyzePanel({
  statement,
  state,
  bindInput,
  onBindInput,
  onEvaluate,
}: {
  statement: string
  state: Loadable<QueryExplainAnalyzeResult>
  bindInput: string
  onBindInput: (value: string) => void
  onEvaluate: () => void
}) {
  const bindCount = highestBindParameter(statement)
  const result = state.data
  return (
    <article className="detail-card explain-analyze-card" aria-live="polite">
      <div className="detail-card-heading">
        <div><span className="panel-kicker">Gerçek kaynak · read-only</span><h2>Ana DB'de EXPLAIN ANALYZE</h2></div>
        <span className="simulation-label"><Database size={14} /> Ana veritabanı</span>
      </div>
      <p className="explain-intro">Bu sorguyu gerçek veri ve cache koşullarıyla ana veritabanında ölçer. Yalnız salt-okunur SELECT kabul edilir; işlem read-only transaction içinde çalıştırılıp geri alınır.</p>
      {bindCount > 0 ? (
        <label className="explain-bind-field">
          <span>Bind değerleri · $1–${bindCount}</span>
          <textarea value={bindInput} onChange={(event) => onBindInput(event.target.value)} disabled={state.status === 'loading'} rows={3} spellCheck={false} aria-label="EXPLAIN ANALYZE bind değerleri" placeholder='["paid", 100, null]' />
          <small className={bindCount > SOURCE_EXPLAIN_MAX_BIND_VALUES ? 'explain-limit-warning' : ''}>{bindCount > SOURCE_EXPLAIN_MAX_BIND_VALUES ? `Bu sorgu ${bindCount} değer istiyor; kaynak EXPLAIN sınırı ${SOURCE_EXPLAIN_MAX_BIND_VALUES} olduğu için çalıştırılamaz.` : `Sorgudaki sırayla tam ${bindCount} JSON scalar değer girin; en fazla ${SOURCE_EXPLAIN_MAX_BIND_VALUES} değer ve toplam 64 KiB.`}</small>
        </label>
      ) : <div className="explain-no-binds"><CheckCircle2 size={16} /><span>Bu sorguda bind parametresi yok; <code>bindValues: []</code> gönderilecek.</span></div>}
      <div className="explain-actions">
        <div><strong>Gerçek kaynakta read-only çalışma</strong><span>Gerçek sorgu yükü ana veritabanında oluşur. Bind değerleri advisor’a kaydedilmez; kaynak DB log/audit politikası geçerlidir. DDL ve yazma sorguları kabul edilmez.</span></div>
        <button type="button" className="hypopg-button explain-run-button" onClick={onEvaluate} disabled={state.status === 'loading' || bindCount > SOURCE_EXPLAIN_MAX_BIND_VALUES}>
          {state.status === 'loading' ? <LoaderCircle className="spin" size={16} /> : <Zap size={16} />}
          {state.status === 'loading' ? 'Kaynakta çalışıyor…' : 'EXPLAIN ANALYZE çalıştır'}
        </button>
      </div>
      {state.status === 'error' && <div className="index-evaluation-error explain-error"><AlertCircle size={17} /><span>{state.error}</span><button type="button" onClick={onEvaluate}>Tekrar dene</button></div>}
      {state.status === 'success' && result && (
        <div className={`explain-result ${result.status.toLowerCase()}`}>
          <div className="index-evaluation-status">
            {result.status === 'RUNTIME_VALIDATED' ? <CheckCircle2 size={19} /> : <ShieldAlert size={19} />}
            <div><strong>{explainStatusLabel(result.status)}</strong><span>{result.message}</span><small>{result.reasonCode}</small></div>
          </div>
          {result.validation && (
            <>
              <div className="explain-metrics">
                <div><span>Çalışma</span><strong>{formatDuration(result.validation.executionTimeMs)}</strong></div>
                <div><span>Planlama</span><strong>{formatDuration(result.validation.planningTimeMs)}</strong></div>
                <div><span>Shared hit / read</span><strong>{formatLargeNumber(result.validation.sharedHitBlocks)} / {formatLargeNumber(result.validation.sharedReadBlocks)}</strong></div>
                <div><span>Temp read / write</span><strong>{formatLargeNumber(result.validation.tempReadBlocks)} / {formatLargeNumber(result.validation.tempWrittenBlocks)}</strong></div>
                <div><span>WAL</span><strong>{formatLargeNumber(result.validation.walRecords)} kayıt · {formatBytes(result.validation.walBytes)}</strong></div>
                <div><span>Safety policy</span><strong>rev. {result.validation.safetyPolicyRevision}</strong><small>PostgreSQL {result.validation.postgresVersion}</small></div>
                <div><span>Çalışma kimliği</span><strong>{result.validation.executionRole}</strong><small>databaseId {result.validation.databaseId}</small></div>
              </div>
              <ExplainPlanErrorBoundary
                resetKey={result.validation.evaluatedAt}
                fallback={(
                  <div className="plan-visualizer-empty" role="alert">
                    <AlertTriangle size={18} />
                    <div><strong>Etkileşimli plan yüklenemedi</strong><span>Plan verisi kaybolmadı; ham JSON aşağıdan incelenebilir.</span></div>
                  </div>
                )}
              >
                <Suspense fallback={<div className="plan-visualizer-loading"><LoaderCircle className="spin" size={16} /> Etkileşimli yürütme planı yükleniyor…</div>}>
                  <ExplainPlanGraph plan={result.validation.plan} />
                </Suspense>
              </ExplainPlanErrorBoundary>
              <ExplainRawPlan plan={result.validation.plan} evaluatedAt={result.validation.evaluatedAt} />
            </>
          )}
          <div className="explain-safety-facts">
            <span><Check size={13} /> {result.executionTarget}</span>
            <span><Check size={13} /> sourceDdlExecuted=false</span>
            {result.validation && <span><Check size={13} /> transactionReadOnly=true</span>}
            <ExplainExecutionAttestation result={result} />
          </div>
        </div>
      )}
    </article>
  )
}

function QueryDetailModal({ queryId, window, onClose }: { queryId: string; window: TimeWindow; onClose: () => void }) {
  const [state, setState] = useState<Loadable<QueryDetail>>({ status: 'loading' })
  const [copied, setCopied] = useState(false)
  const [indexAdvice, setIndexAdvice] = useState<Record<string, Loadable<QueryIndexAdvice>>>({})
  const [copiedIndexKey, setCopiedIndexKey] = useState<string | null>(null)
  const [explainState, setExplainState] = useState<Loadable<QueryExplainAnalyzeResult>>({ status: 'idle' })
  const [bindInput, setBindInput] = useState('[]')
  const detailControllerRef = useRef<AbortController | null>(null)
  const explainControllerRef = useRef<AbortController | null>(null)
  const closeRef = useRef<HTMLButtonElement>(null)

  const load = () => {
    detailControllerRef.current?.abort()
    const controller = new AbortController()
    detailControllerRef.current = controller
    setState({ status: 'loading' })
    setIndexAdvice({})
    explainControllerRef.current?.abort()
    setExplainState({ status: 'idle' })
    setBindInput('[]')
    advisorApi.getQuery(queryId, window, controller.signal).then(({ data }) => {
      if (!controller.signal.aborted) setState({ status: 'success', data })
    }).catch((error: unknown) => {
      if (controller.signal.aborted) return
      setState({ status: 'error', error: error instanceof Error ? error.message : 'Sorgu detayı alınamadı.' })
    })
  }

  useEffect(() => {
    load()
    closeRef.current?.focus()
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    document.addEventListener('keydown', onKeyDown)
    document.body.classList.add('modal-open')
    return () => {
      detailControllerRef.current?.abort()
      explainControllerRef.current?.abort()
      document.removeEventListener('keydown', onKeyDown)
      document.body.classList.remove('modal-open')
    }
    // queryId değiştiğinde yeni detay yüklenir; onClose kimliği modal ömründe sabittir.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryId, window])

  const copySql = async () => {
    if (!state.data) return
    await navigator.clipboard.writeText(state.data.fullSql)
    setCopied(true)
    globalThis.setTimeout(() => setCopied(false), 1800)
  }

  const evaluateIndex = async (predicate: QueryPredicate) => {
    const key = predicateAdviceKey(predicate)
    setIndexAdvice((current) => ({ ...current, [key]: { status: 'loading' } }))
    try {
      const { data } = await advisorApi.evaluateIndex(queryId, window, predicate)
      setIndexAdvice((current) => ({ ...current, [key]: { status: 'success', data } }))
    } catch (error: unknown) {
      setIndexAdvice((current) => ({
        ...current,
        [key]: { status: 'error', error: error instanceof Error ? error.message : 'HypoPG doğrulaması alınamadı.' },
      }))
    }
  }

  const evaluateCompositeIndex = async (candidate: CompositeIndexCandidate) => {
    const key = `composite:${candidate.candidateId}`
    setIndexAdvice((current) => ({ ...current, [key]: { status: 'loading' } }))
    try {
      const { data } = await advisorApi.evaluateCompositeIndex(queryId, window, candidate)
      setIndexAdvice((current) => ({ ...current, [key]: { status: 'success', data } }))
    } catch (error: unknown) {
      setIndexAdvice((current) => ({
        ...current,
        [key]: { status: 'error', error: error instanceof Error ? error.message : 'Composite HypoPG doğrulaması alınamadı.' },
      }))
    }
  }

  const evaluateExplainAnalyze = async () => {
    if (!state.data) return
    const parsed = parseExplainBindValues(bindInput, highestBindParameter(state.data.fullSql))
    if ('error' in parsed) {
      setExplainState({ status: 'error', error: parsed.error })
      return
    }
    explainControllerRef.current?.abort()
    const controller = new AbortController()
    explainControllerRef.current = controller
    setExplainState({ status: 'loading' })
    try {
      const { data } = await advisorApi.explainAnalyzeQuery(queryId, window, parsed.values, controller.signal)
      if (!controller.signal.aborted) setExplainState({ status: 'success', data })
    } catch (error: unknown) {
      if (controller.signal.aborted) return
      setExplainState({ status: 'error', error: error instanceof Error ? error.message : 'Kaynak EXPLAIN ANALYZE çalıştırılamadı.' })
    }
  }

  const updateExplainBindInput = (value: string) => {
    explainControllerRef.current?.abort()
    explainControllerRef.current = null
    setBindInput(value)
    setExplainState({ status: 'idle' })
  }

  const copyIndexSql = async (key: string, statement: string) => {
    try {
      await navigator.clipboard.writeText(statement)
      setCopiedIndexKey(key)
      globalThis.setTimeout(() => setCopiedIndexKey(null), 1800)
    } catch {
      setIndexAdvice((current) => ({ ...current, [key]: { status: 'error', error: 'Index SQL’i panoya kopyalanamadı.' } }))
    }
  }

  const totalSharedBlocks = (state.data?.sharedBlocksHit ?? 0) + (state.data?.sharedBlocksRead ?? 0)
  const cacheHitPercent = totalSharedBlocks > 0 ? ((state.data?.sharedBlocksHit ?? 0) / totalSharedBlocks) * 100 : null
  const cacheHitLabel = state.data ? formatCacheHit(state.data.sharedBlocksHit, state.data.sharedBlocksRead) : '—'

  return (
    <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose() }}>
      <section className="query-modal" role="dialog" aria-modal="true" aria-labelledby="query-modal-title">
        <div className="modal-topbar">
          <button ref={closeRef} type="button" className="modal-back-button" onClick={onClose}><ArrowLeft size={17} /> Sorgulara dön</button>
          <span className="modal-context"><Database size={14} /> PostgreSQL Advisor</span>
          <button type="button" className="icon-button" onClick={onClose} aria-label="Detayı kapat"><X size={19} /></button>
        </div>
        {state.status === 'loading' && <LoadingPanel label="Sorgu detayı hazırlanıyor" />}
        {state.status === 'error' && <ErrorPanel message={state.error ?? 'Detay alınamadı.'} onRetry={load} />}
        {state.status === 'success' && state.data && (
          <div className="modal-scroll">
            <div className="query-detail-hero">
              <div className="query-detail-title">
                <div className="query-title-meta"><QueryImpactBadge severity={state.data.severity} /><code>{state.data.fingerprint}</code><span>{state.data.database}</span></div>
                <h1 id="query-modal-title">{state.data.title}</h1>
                <p>{windowLabels[window]} · İlk örnek {formatDateTime(state.data.firstSeenAt)} · Son örnek {formatDateTime(state.data.lastSeenAt)}</p>
              </div>
              <div className="hero-score"><ImpactRing impact={state.data.impactScore} severity={state.data.severity} /><div><strong>İnceleme puanı</strong><span>Yükseldikçe önce bakılma sırası artar</span></div></div>
            </div>

            <div className="modal-reading-guide">
              <ReadingGuide>Yüksek inceleme puanı önce bakılması gereken sorguyu, pozitif değişim ise yavaşlamayı gösterir. Bu puan yalnızca sıralama yapar; SQL üzerinde otomatik değişiklik yapmaz. Gerçek CPU oranını DB süresiyle, filesystem I/O'yu shared bloklarla birlikte okuyun.</ReadingGuide>
            </div>

            <div className="query-detail-layout">
              <main className="query-detail-main">
                <article className="detail-card sql-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Normalize edilmiş sorgu</span><h2>SQL</h2></div><button type="button" className="copy-sql-button" onClick={copySql}>{copied ? <Check size={15} /> : <Clipboard size={15} />}{copied ? 'Kopyalandı' : 'SQL’i kopyala'}</button></div>
                  <pre><code>{state.data.fullSql}</code></pre>
                </article>

                <ExplainAnalyzePanel statement={state.data.fullSql} state={explainState} bindInput={bindInput} onBindInput={updateExplainBindInput} onEvaluate={evaluateExplainAnalyze} />

                <article className="detail-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">{windowLabels[window]}</span><h2>Çalışma süresi eğilimi</h2></div>{state.data.hasComparison
                    ? <span className={`change ${regressionValue(state.data) > 0 ? 'negative' : 'positive'}`}>{regressionValue(state.data) > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />} %{formatNumber(Math.abs(regressionValue(state.data)))}</span>
                    : <span className="change unavailable">{comparisonStatusLabel(state.data)}</span>}
                  </div>
                  <MiniTrend points={state.data.trend.map((point) => ({ label: point.label.replace(' Tem', ''), value: point.durationMs }))} tone={!state.data.hasComparison ? 'blue' : regressionValue(state.data) > 0 ? 'red' : 'green'} height={142} label={`Sorgunun ${windowLabels[window].toLocaleLowerCase('tr')} çalışma süresi`} />
                  <div className="trend-metrics"><div><span>Ortalama</span><strong>{formatDuration(state.data.avgDurationMs)}</strong></div><div><span>Çağrı</span><strong>{formatLargeNumber(state.data.calls)}</strong></div><div><span>Okunan shared blok</span><strong>{formatLargeNumber(state.data.sharedBlocksRead)}</strong></div><div><span>Toplam süre</span><strong>{formatDuration(state.data.totalTimeMs)}</strong></div>{state.data.rowsPerCall !== undefined && <div><span>Satır / çağrı</span><strong>{formatNumber(state.data.rowsPerCall)}</strong></div>}{state.data.p95DurationMs !== undefined && <div><span>Gerçek p95</span><strong>{formatDuration(state.data.p95DurationMs)}</strong></div>}</div>
                  {state.data.p95DurationMs === undefined && state.data.durationDistribution?.available === false && <div className="metric-unavailable"><Info size={15} /><span><strong>p95 gösterilemiyor.</strong> {state.data.durationDistribution.reason || 'PoWA yürütme süresi dağılımını saklamıyor.'}</span></div>}
                </article>

                <article className="detail-card cpu-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">pg_stat_kcache {state.data.cpu.capability.version || ''}</span><h2>Gerçek CPU ve işletim sistemi I/O'su</h2></div><span className="simulation-label"><Activity size={14} /> Skora dahil değil</span></div>
                  <div className="predicate-scope-note"><Info size={16} /><span>{state.data.cpu.capability.reason} Bu metrik bu iterasyonda yalnız gözlemdir ve inceleme puanını değiştirmez.</span></div>
                  {!state.data.cpu.capability.available ? (
                    <div className="predicate-empty"><ShieldAlert size={20} /><div><strong>CPU telemetrisi kapalı</strong><p>Kaynakta pg_stat_kcache preload, extension ve PoWA datasource kaydı gerekir.</p></div></div>
                  ) : !state.data.cpu.capability.dataAvailable ? (
                    <div className="predicate-empty"><Clock3 size={20} /><div><strong>CPU verisi henüz oluşmadı</strong><p>Aynı sorgu iki collector snapshot'ı arasında çalıştığında reset-safe fark metrikleri görünür.</p></div></div>
                  ) : (
                    <div className="cpu-metric-grid">
                      <div><span>Toplam CPU</span><strong>{formatDuration(state.data.cpu.totalTimeMs ?? 0)}</strong><small>%{formatNumber(state.data.cpu.percentOfExecTime ?? 0)} DB süresi</small></div>
                      <div><span>User CPU</span><strong>{formatDuration(state.data.cpu.userTimeMs ?? 0)}</strong><small>uygulama kodu</small></div>
                      <div><span>System CPU</span><strong>{formatDuration(state.data.cpu.systemTimeMs ?? 0)}</strong><small>kernel çağrıları</small></div>
                      <div><span>Filesystem okuma</span><strong>{state.data.cpu.filesystemReadsBytes === null ? '—' : formatBytes(state.data.cpu.filesystemReadsBytes)}</strong><small>OS katmanı</small></div>
                      <div><span>Filesystem yazma</span><strong>{state.data.cpu.filesystemWritesBytes === null ? '—' : formatBytes(state.data.cpu.filesystemWritesBytes)}</strong><small>OS katmanı</small></div>
                    </div>
                  )}
                </article>

                <article className="detail-card wait-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">pg_wait_sampling {state.data.waits.capability.release}</span><h2>Sampled wait profili</h2></div><span className="simulation-label"><Clock3 size={14} /> Skora dahil değil</span></div>
                  <div className="predicate-scope-note"><Info size={16} /><span>{state.data.waits.capability.reason}</span></div>
                  {!state.data.waits.capability.available ? (
                    <div className="predicate-empty"><ShieldAlert size={20} /><div><strong>Wait telemetrisi kapalı</strong><p>Kaynakta pg_wait_sampling preload, extension ve PoWA datasource kaydı gerekir.</p></div></div>
                  ) : !state.data.waits.capability.dataAvailable ? (
                    <div className="predicate-empty"><Clock3 size={20} /><div><strong>Wait hattı hazırlanıyor</strong><p>Collector ilk snapshot'ı tamamladığında sıfır wait ile veri yokluğu ayrılacaktır.</p></div></div>
                  ) : !state.data.waits.totalSamples ? (
                    <div className="predicate-empty"><CheckCircle2 size={20} /><div><strong>Sampled wait görülmedi</strong><p>Bu tek başına CPU darboğazı kanıtı değildir; kcache CPU oranıyla birlikte okuyun.</p></div></div>
                  ) : (
                    <>
                      <div className="cpu-metric-grid">
                        <div><span>Toplam wait örneği</span><strong>{formatLargeNumber(state.data.waits.totalSamples)}</strong><small>duvar saati değildir</small></div>
                        <div><span>Baskın kategori</span><strong>{state.data.waits.dominant?.category || 'Karışık'}</strong><small>{state.data.waits.dominant ? `%${formatNumber(state.data.waits.dominant.sharePercent)} wait dağılımı` : 'düşük örnek'}</small></div>
                        <div><span>Baskın event</span><strong>{state.data.waits.dominant?.event || '—'}</strong><small>{state.data.waits.dominant?.confidence === 'MEDIUM' ? 'orta kanıt' : 'düşük kanıt'}</small></div>
                      </div>
                      <div className="wait-event-list">
                        {state.data.waits.events.slice(0, 8).map((event) => <div key={`${event.eventType}:${event.event}`}><span>{event.category} · {event.event}</span><strong>{formatLargeNumber(event.samples)} · %{formatNumber(event.sharePercent)}</strong></div>)}
                      </div>
                    </>
                  )}
                </article>

                <article className="detail-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Advisor bulguları</span><h2>Neden öncelikli?</h2></div><span className="finding-count">{state.data.findings.length} bulgu</span></div>
                  <div className="findings-list">
                    {state.data.findings.map((finding, index) => (
                      <div key={finding.id} className={`finding-item ${finding.severity}`}>
                        <span className="finding-number">{index + 1}</span>
                        <div><div className="finding-title"><SeverityBadge severity={finding.severity} /><h3>{finding.title}</h3></div><p>{finding.description}</p><div className="recommendation"><Sparkles size={16} /><div><strong>Öneri</strong><span>{finding.recommendation}</span></div></div></div>
                      </div>
                    ))}
                  </div>
                </article>

                <article className="detail-card predicate-card">
                  <div className="detail-card-heading">
                    <div><span className="panel-kicker">pg_qualstats {state.data.predicates.capability.version || ''}</span><h2>WHERE filtreleri ve index adayı gözlemleri</h2></div>
                    <span className="finding-count">{state.data.predicates.items.length} gözlem</span>
                  </div>
                  <div className="predicate-scope-note"><Info size={16} /><span>{state.data.predicates.capability.reason} Bu alan otomatik <code>CREATE INDEX</code> çalıştırmaz.</span></div>
                  {!state.data.predicates.capability.available ? (
                    <div className="predicate-empty"><ShieldAlert size={20} /><div><strong>Predicate telemetrisi kapalı</strong><p>Kaynak sunucuda pg_qualstats ve PoWA datasource kaydını etkinleştirin.</p></div></div>
                  ) : state.data.predicates.items.length ? (
                    <div className="predicate-list">
                      {state.data.predicates.items.map((predicate) => (
                        <div className={`predicate-item ${predicate.signal.toLowerCase()}`} key={`${predicate.qualId}:${predicate.relationId}:${predicate.evalType}`}>
                          <div className="predicate-item-heading">
                            <div><strong>{predicate.schemaName}.{predicate.tableName}</strong><span>{predicate.columns.length ? predicate.columns.join(', ') : `relation OID ${predicate.relationId}`}</span></div>
                            <SeverityBadge severity={predicateSignalSeverity(predicate.signal)} label={predicateSignalLabel(predicate.signal)} />
                          </div>
                          <div className="predicate-metrics">
                            <div><span>Eleme oranı</span><strong>{predicate.filterRatio == null ? '—' : `%${formatNumber(predicate.filterRatio * 100)}`}</strong></div>
                            <div><span>Örneklenen çalışma</span><strong>{formatLargeNumber(predicate.occurrences)}</strong></div>
                            <div><span>İşlenen satır</span><strong>{formatLargeNumber(predicate.rowsProcessed)}</strong></div>
                            <div><span>Elenen satır</span><strong>{formatLargeNumber(predicate.rowsFiltered)}</strong></div>
                          </div>
                          <div className="predicate-recommendation"><Sparkles size={16} /><div><strong>Güvenli öneri</strong><span>{predicate.recommendation}</span></div></div>
                          <small className="predicate-footnote">{predicate.sampleCount} snapshot · {predicate.evalType === 'FILTER' ? 'scan sonrası WHERE filtresi' : predicate.evalType === 'INDEX_CONDITION' ? 'index koşulu' : 'predicate türü bilinmiyor'} · operator OID {predicate.operatorOids.join(', ') || 'yok'}</small>
                          <PredicateIndexEvaluation
                            predicate={predicate}
                            state={indexAdvice[predicateAdviceKey(predicate)]}
                            copied={copiedIndexKey === predicateAdviceKey(predicate)}
                            onEvaluate={() => evaluateIndex(predicate)}
                            onCopy={(statement) => copyIndexSql(predicateAdviceKey(predicate), statement)}
                          />
                        </div>
                      ))}
                    </div>
                  ) : (
                    <div className="predicate-empty"><Info size={20} /><div><strong>Bu pencerede predicate örneği yok</strong><p>Sorgu yeniden çalışıp collector snapshot aldığında bu alan otomatik dolar.</p></div></div>
                  )}
                </article>

                <article className="detail-card predicate-card">
                  <div className="detail-card-heading">
                    <div><span className="panel-kicker">JOIN snapshotter · reset boundary</span><h2>JOIN ilişkileri ve composite index adayları</h2></div>
                    <span className="finding-count">{state.data.predicates.joins.length} JOIN · {state.data.predicates.candidates.length} aday</span>
                  </div>
                  <div className="predicate-scope-note"><Info size={16} /><span>{state.data.predicates.joinCapability.reason} JOIN ve aday kanıtları skora dahil değildir; hiçbir DDL kaynakta otomatik çalışmaz.</span></div>
                  {!state.data.predicates.joinCapability.available ? (
                    <div className="predicate-empty"><ShieldAlert size={20} /><div><strong>JOIN snapshotter kapalı</strong><p>Kaynak outbox ve düşük yetkili snapshotter servisini etkinleştirin.</p></div></div>
                  ) : <>
                    {state.data.predicates.joins.length ? <div className="predicate-list join-list">
                      {state.data.predicates.joins.map((join) => <div className={`predicate-item ${join.signal.toLowerCase()}`} key={`${join.qualNodeId}:${join.leftRelationId}:${join.rightRelationId}`}>
                        <div className="predicate-item-heading"><div><strong>{join.leftSchemaName}.{join.leftTableName}.{join.leftColumnName}</strong><span>{join.operatorName || `operator ${join.operatorOid}`} → {join.rightSchemaName}.{join.rightTableName}.{join.rightColumnName}</span></div><SeverityBadge severity={join.signal === 'FREQUENT_JOIN' ? 'healthy' : 'warning'} label={join.signal === 'FREQUENT_JOIN' ? 'Sık JOIN' : join.signal === 'OBSERVED_JOIN' ? 'JOIN gözlendi' : 'Yetersiz örnek'} /></div>
                        <div className="predicate-metrics"><div><span>Örneklenen çalışma</span><strong>{formatLargeNumber(join.occurrences)}</strong></div><div><span>İşlenen satır</span><strong>{formatLargeNumber(join.rowsProcessed)}</strong></div><div><span>Snapshot</span><strong>{formatLargeNumber(join.sampleCount)}</strong></div><div><span>B-tree stratejisi</span><strong>{join.btreeStrategy ?? '—'}</strong></div></div>
                        <small className="predicate-footnote">qualnode {join.qualNodeId} · scoreIncluded=false</small>
                      </div>)}
                    </div> : <div className="predicate-empty"><Info size={20} /><div><strong>Bu sorgu için JOIN örneği yok</strong><p>Bu sonuç sorguda JOIN olmadığını kanıtlamaz; örnekleme ve pencere kapsamını da kontrol edin.</p></div></div>}
                    {state.data.predicates.candidates.length > 0 && <div className="predicate-list composite-list">
                      {state.data.predicates.candidates.map((candidate) => {
                        const key = `composite:${candidate.candidateId}`
                        return <CompositeIndexEvaluation key={candidate.candidateId} candidate={candidate} state={indexAdvice[key]} copied={copiedIndexKey === key} onEvaluate={() => evaluateCompositeIndex(candidate)} onCopy={(statement) => copyIndexSql(key, statement)} />
                      })}
                    </div>}
                  </>}
                </article>

                <article className="detail-card comparison-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Gerçek telemetri</span><h2>Önceki / mevcut pencere</h2></div><span className="simulation-label"><Activity size={14} /> PoWA karşılaştırması</span></div>
                  {state.data.hasComparison ? <div className="comparison-grid">
                    {state.data.comparison.map((item) => (
                      <div key={item.metric} className={`comparison-item ${item.improvementPercent >= 0 ? 'improved' : 'regressed'}`}>
                        <span>{item.metric}</span>
                        <div className="comparison-values"><del>{formatNumber(item.before)} {item.unit}</del><ArrowRight size={16} /><strong>{formatNumber(item.after)} {item.unit}</strong></div>
                        <div className="improvement-bar"><i style={{ width: `${Math.min(100, Math.abs(item.improvementPercent))}%` }} /></div>
                        <small>%{formatNumber(Math.abs(item.improvementPercent))} {item.improvementPercent >= 0 ? 'daha iyi' : 'daha yavaş'}</small>
                      </div>
                    ))}
                  </div> : <div className="comparison-unavailable"><Clock3 size={18} /><div><strong>{comparisonStatusLabel(state.data)}</strong><p>{comparisonStatusDetail(state.data)}</p></div></div>}
                </article>
              </main>

              <aside className="query-detail-aside">
                <article className="detail-card score-breakdown-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">İnceleme önceliği</span><h2>Puanın nedenleri</h2></div></div>
                  <p className="score-model-note"><Info size={14} /> Bu bölüm yalnızca puan hesaplar ve sorguları öncelik sırasına dizer; veritabanında otomatik değişiklik yapmaz.</p>
                  <div className="score-breakdown-list">
                    {state.data.scoreBreakdown.map((item) => (
                      <div key={item.key} className="breakdown-item">
                        <div><strong>{item.label}</strong><span>{formatScoreContribution(item.contribution)} puan · en fazla {item.maxContribution}</span></div>
                        <div className="breakdown-bar"><i style={{ width: `${item.maxContribution ? Math.min(100, (item.contribution / item.maxContribution) * 100) : 0}%` }} /></div>
                        <small>{item.hint}</small><small className="score-effect">{item.key === 'regression' && !state.data!.hasComparison ? 'Önceki dönem verisi olmadığı için bu başlık puanlanmadı.' : scoreContributionLabel(item.contribution, item.maxContribution)}</small><div className="breakdown-raw"><b>Ölçülen yük</b><span>{scoreMetricValue(item, state.data!)}</span></div>
                        {item.key === 'regression' && !state.data!.hasComparison ? <div className="score-factors"><span>Karşılaştırma için yeterli geçmiş yok</span></div> : (item.percentileScore !== undefined || item.volumeFactor !== undefined || item.fullScoreAt !== undefined) && <div className="score-factors">{item.percentileScore !== undefined && <span title={'Teknik göreli sıra: %' + formatNumber(item.percentileScore)}>{scoreRelativeLabel(item.percentileScore)}</span>}{item.volumeFactor !== undefined && <span title={'Teknik hacim katsayısı: ' + formatVolumeFactor(item.volumeFactor)}>{scoreVolumeLabel(item.volumeFactor)}</span>}{scoreThresholdValue(item) && <span>Bu başlıktan tam puan için: {scoreThresholdValue(item)}</span>}</div>}
                      </div>
                    ))}
                  </div>
                </article>

                <article className="detail-card io-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Buffer kullanımı</span><h2>I/O özeti</h2></div></div>
                  <div className="io-visual"><div style={{ '--hit-ratio': `${cacheHitPercent ?? 0}%` } as React.CSSProperties}><span /></div><strong>{cacheHitLabel}</strong><small>{cacheHitPercent === null ? 'ölçüm yok' : 'cache hit'}</small></div>
                  <div className="io-stats"><span><i className="hit" />Cache hit <b>{formatLargeNumber(state.data.sharedBlocksHit)} blok</b></span><span><i className="read" />Okunan shared blok <b>{formatLargeNumber(state.data.sharedBlocksRead)} blok</b></span></div>
                </article>
              </aside>
            </div>
          </div>
        )}
      </section>
    </div>
  )
}

function SystemHealthPage({ state, onRetry }: { state: Loadable<SystemHealth>; onRetry: () => void }) {
  if (state.status === 'loading' || state.status === 'idle') return <LoadingPanel label="Sistem metrikleri yükleniyor" />
  if (state.status === 'error' || !state.data) return <ErrorPanel message={state.error ?? 'Sistem metrikleri alınamadı.'} onRetry={onRetry} />
  const data = state.data

  return (
    <section className="page-section" aria-labelledby="health-title">
      <PageHeading eyebrow={data.postgresVersion} title="Tablo ve işlem sinyalleri" description={`Son ölçüm ${formatDateTime(data.collectedAt)} tarihinde alındı.`}>
        <SeverityBadge severity={data.overall} label={data.overall === 'healthy' ? 'Öncelikli sinyal yok' : 'İzlenmesi gereken sinyal var'} />
        <button type="button" className="secondary-button" onClick={onRetry}><RefreshCw size={15} /> Yenile</button>
      </PageHeading>

      <ReadingGuide>Yeşil değerler hedef içinde, turuncu ve kırmızı değerler inceleme gerektirir. Ölü satır veya uzun transaction sayısı yükseliyorsa ilgili tabloyu ve işlem süresini kontrol edin; tek bir sayaç tek başına sorun kanıtı değildir.</ReadingGuide>

      <div className="health-grid">
        {data.metrics.map((metric) => (
          <article key={metric.key} className={`health-metric-card ${metric.severity}`}>
            <div className="health-card-top"><span className="metric-label">{metric.label}</span><SeverityBadge severity={metric.severity} /></div>
            <div className="health-value"><strong>{formatNumber(metric.value)}</strong><span>{metric.unit}</span><small>hedef {metric.target}</small></div>
            {metric.history.length > 1 && <MiniTrend points={metric.history} tone={metric.severity === 'healthy' ? 'green' : metric.severity === 'critical' ? 'red' : 'orange'} height={72} label={`${metric.label} geçmişi`} />}
            <p>{metric.description}</p>
          </article>
        ))}
      </div>

      <div className="health-main-grid">
        <article className="panel database-health-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Veritabanı düzeyi</span><h2>Kaynak dağılımı</h2></div><Database size={20} className="panel-accent-icon" /></div>
          <div className="database-health-table-wrap">
            <table className="database-health-table">
              <thead><tr><th>Veritabanı</th><th>Boyut</th><th>Tablo</th><th>Tam tarama</th><th>Dizinli okuma</th><th>Ölü satır</th><th>Sinyal</th><th>Durum</th></tr></thead>
              <tbody>{data.databases.map((database) => <tr key={`${database.serverId}:${database.databaseId}`}><td><span className="db-name"><Database size={15} />{database.name}</span></td><td>{formatNumber(database.sizeGb)} GB</td><td>{database.tableCount}</td><td>{formatNumber(database.sequentialScans, true)}</td><td>{formatNumber(database.indexScans, true)}</td><td>{formatNumber(database.deadTuples, true)}</td><td>{database.signals}</td><td><SeverityBadge severity={database.severity} /></td></tr>)}</tbody>
            </table>
          </div>
        </article>

        <article className="panel health-advice-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Advisor yorumu</span><h2>Bugün ne yapmalı?</h2></div><Sparkles size={19} className="panel-accent-icon" /></div>
          <div className="health-advice-list">
            <div className={data.overall === 'healthy' ? 'health-advice healthy' : 'health-advice warning'}><span><Info size={17} /></span><div><strong>{data.databases.reduce((sum, item) => sum + item.signals, 0)} öncelikli tablo sinyali</strong><p>Bu tabloları iş yükü ve bakım geçmişiyle birlikte inceleyin.</p></div></div>
            <div className="health-advice healthy"><span><CheckCircle2 size={17} /></span><div><strong>{data.capabilities.filter((item) => item.available).length} telemetri yeteneği aktif</strong><p>{data.capabilities.filter((item) => item.available).map((item) => item.label).join(', ') || 'Kaynaklar henüz raporlanmadı.'}</p></div></div>
            {data.capabilities.find((item) => !item.available) && <div className="health-advice warning"><span><AlertCircle size={17} /></span><div><strong>{data.capabilities.find((item) => !item.available)?.label} kullanılamıyor</strong><p>{data.capabilities.find((item) => !item.available)?.reason || 'Sunucu sürümü bu veri kaynağını sağlamıyor.'}</p></div></div>}
          </div>
        </article>
      </div>
    </section>
  )
}

function statusSeverity(status?: string): Severity {
  const value = (status || '').toUpperCase()
  if (['HEALTHY', 'RUNNING', 'UP', 'OK'].includes(value)) return 'healthy'
  if (['FAILED', 'ERROR', 'DOWN', 'CRITICAL'].includes(value)) return 'critical'
  return 'warning'
}

function indexSignalLabel(signal?: string): string {
  const labels: Record<string, string> = {
    INSUFFICIENT_DATA: 'Yetersiz gözlem',
    NO_SCANS_OBSERVED: 'Tarama gözlenmedi',
    LOW_USAGE_OBSERVED: 'Düşük kullanım gözlendi',
    HEALTHY: 'Belirgin sinyal yok',
  }
  return labels[(signal || '').toUpperCase()] || signal || 'Bilgi'
}

function OperationsPage({ state, window, onRetry }: { state: Loadable<OperationsData>; window: TimeWindow; onRetry: () => void }) {
  if (state.status === 'loading' || state.status === 'idle') return <LoadingPanel label="Operasyon telemetrisi yükleniyor" />
  if (state.status === 'error' || !state.data) return <ErrorPanel message={state.error ?? 'Operasyon telemetrisi alınamadı.'} onRetry={onRetry} />
  const data = state.data
  const io = data.io.summary
  const indexSummary = data.indexes.summary
  const databaseBlocksRead = data.io.items.reduce((total, item) => total + item.sharedBlocksRead, 0)
  const databaseBlocksHit = data.io.items.reduce((total, item) => total + item.sharedBlocksHit, 0)
  const operationsCacheHitLabel = formatCacheHit(databaseBlocksHit, databaseBlocksRead)

  return (
    <section className="page-section operations-page" aria-labelledby="operations-title">
      <PageHeading eyebrow={`Repository görünürlüğü · ${windowLabels[window]}`} title="Operasyonlar ve telemetri" description="Collector, saklama kapasitesi, index kullanımı ve veritabanı I/O akışını tek yerde izleyin.">
        <button type="button" className="secondary-button" onClick={onRetry}><RefreshCw size={15} /> Yenile</button>
      </PageHeading>

      <ReadingGuide>Bu ekran repository’ye zaten kaydedilen sunucu düzeyi verileri görünür kılar. Index gözlemleri otomatik silme önerisi değildir; tablo yazma yükü ve sorgu planlarıyla doğrulanmalıdır.</ReadingGuide>

      <div className="stats-grid operations-stats">
        <StatCard icon={Database} label="Repository boyutu" value={formatBytes(data.repository.sizeBytes)} tone="blue" helper={`PostgreSQL ${data.repository.postgresVersion || '—'} · PoWA ${data.repository.powaVersion || '—'}`} />
        <StatCard icon={Clock3} label="Saklama hedefi" value={formatNumber(data.repository.retentionDays)} unit="gün" tone="green" helper={`Collector kaydı: ${data.collector.retention || 'henüz yok'}`} />
        <StatCard icon={Activity} label="Collector gecikmesi" value={data.collector.lagSeconds == null ? '—' : formatDuration(data.collector.lagSeconds * 1000)} tone={statusSeverity(data.collector.status) === 'healthy' ? 'green' : 'orange'} helper={`Durum: ${data.collector.status || 'bilinmiyor'} · sıklık ${data.collector.frequencySeconds ?? '—'} sn`} />
        <StatCard icon={Network} label="İzlenen kaynak" value={formatNumber(data.architecture.sourceCount)} tone="blue" helper={`${data.collectors.length} collector kaydı repository'de görünür`} />
      </div>

      <div className="operations-top-grid">
        <article className="panel architecture-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Veri yolu</span><h2>Repository-only mimari</h2></div><Network size={20} className="panel-accent-icon" /></div>
          <div className="operations-flow">{data.architecture.dataFlow.map((step, index) => <div key={`${step}-${index}`}><span>{index + 1}</span><strong>{step}</strong>{index < data.architecture.dataFlow.length - 1 && <ArrowRight size={17} />}</div>)}</div>
          <p className="architecture-note"><ShieldAlert size={15} /> API’nin kaynak PostgreSQL’e doğrudan bağlantısı {data.architecture.apiSourceConnection ? 'açık' : 'kapalı'}; analiz repository üzerinden yapılır.</p>
        </article>
        <article className="panel service-panel">
          <div className="panel-heading"><div><span className="panel-kicker">Çalışma durumu</span><h2>Servisler</h2></div><Activity size={19} className="panel-accent-icon" /></div>
          <div className="service-status-list">{data.services.map((service) => <div key={service.service}><span className={`service-dot ${statusSeverity(service.status)}`}><i /></span><div><strong>{service.name}</strong><small>{service.service}</small></div><SeverityBadge severity={statusSeverity(service.status)} label={service.status} /></div>)}</div>
        </article>
      </div>

      {data.collectors.length > 0 && <article className="panel telemetry-panel collector-telemetry-panel">
        <div className="panel-heading"><div><span className="panel-kicker">Kaynak bazında</span><h2>Collector ve retention kayıtları</h2></div><Activity size={19} className="panel-accent-icon" /></div>
        <div className="database-health-table-wrap telemetry-table-wrap"><table className="database-health-table"><thead><tr><th>Kaynak</th><th>Bağlantı</th><th>Snapshot sıklığı</th><th>Retention</th><th>Son snapshot</th><th>Gecikme</th><th>Durum</th></tr></thead><tbody>{data.collectors.map((collector, index) => <tr key={collector.serverId ?? `${collector.alias}-${index}`}><td><span className="index-name"><strong>{collector.alias || `server-${collector.serverId || '—'}`}</strong><small>server id {collector.serverId ?? '—'}</small></span></td><td>{collector.hostname || '—'}{collector.port ? `:${collector.port}` : ''}</td><td>{collector.frequencySeconds == null ? '—' : `${formatNumber(collector.frequencySeconds)} sn`}</td><td>{collector.retention || '—'}</td><td>{collector.lastSnapshotAt ? formatDateTime(collector.lastSnapshotAt) : '—'}</td><td>{collector.lagSeconds == null ? '—' : formatDuration(collector.lagSeconds * 1000)}</td><td><SeverityBadge severity={statusSeverity(collector.status)} label={collector.status || 'UNKNOWN'} /></td></tr>)}</tbody></table></div>
      </article>}

      <article className="panel telemetry-panel">
        <div className="panel-heading"><div><span className="panel-kicker">PostgreSQL I/O · {windowLabels[window]}</span><h2>Okuma, yazma ve WAL özeti</h2></div><Gauge size={20} className="panel-accent-icon" /></div>
        {data.io.available && io ? <>
          <div className="telemetry-metric-grid">
            <div><span>Okunan veri</span><strong>{formatBytes(io.readBytes)}</strong><small>{formatLargeNumber(io.reads)} okuma</small></div>
            <div><span>Yazılan veri</span><strong>{formatBytes(io.writeBytes)}</strong><small>{formatLargeNumber(io.writes)} yazma</small></div>
            <div><span>Extend</span><strong>{formatBytes(io.extendBytes)}</strong><small>ilişki genişletme I/O'su</small></div>
            <div><span>Cache hit</span><strong>{operationsCacheHitLabel}</strong><small>{formatLargeNumber(io.cacheHits)} hit</small></div>
            <div><span>Temp / WAL</span><strong>{formatBytes(io.tempBytes)} / {formatBytes(io.walBytes)}</strong><small>geçici veri / WAL</small></div>
            <div><span>Checkpoint</span><strong>{formatLargeNumber(io.checkpoints)}</strong><small>{formatDuration(io.checkpointWriteTimeMs)} yazma süresi</small></div>
            <div><span>Backend yazması</span><strong>{formatLargeNumber(io.backendWrites)}</strong><small>buffer yazma yükü</small></div>
          </div>

          {data.io.capabilities.length > 0 && <div className="telemetry-capability-grid">{data.io.capabilities.map((capability) => <div key={capability.key}><strong>{capability.source}</strong><span>{capability.available ? 'Kullanılabilir' : 'Kullanılamıyor'} · {capability.resetEpochAware ? 'reset-aware' : 'reset sınırlı'}</span></div>)}</div>}
          {data.io.capabilities.filter((capability) => capability.limitation).map((capability) => <p className="telemetry-caveat" key={`${capability.key}-limitation`}><ShieldAlert size={15} /> <span><b>{capability.source}:</b> {capability.limitation}</span></p>)}

          <div className="database-health-table-wrap telemetry-table-wrap"><table className="database-health-table"><thead><tr><th>Veritabanı</th><th>Bağlantı</th><th>Commit / rollback</th><th>Blok read / hit</th><th>Satır return / fetch</th><th>Satır insert / update / delete</th><th>Temp</th><th>Deadlock</th><th>I/O süresi</th></tr></thead><tbody>{data.io.items.map((item) => <tr key={`${item.serverId}:${item.databaseId}`}><td><span className="db-name"><Database size={14} />{item.serverAlias ? `${item.serverAlias} / ` : ''}{item.databaseName}</span></td><td>{formatNumber(item.currentBackends || 0)}</td><td>{formatLargeNumber(item.transactionsCommitted || 0)} / {formatLargeNumber(item.transactionsRolledBack || 0)}</td><td>{formatLargeNumber(item.sharedBlocksRead)} / {formatLargeNumber(item.sharedBlocksHit)}<small>{formatCacheHit(item.sharedBlocksHit, item.sharedBlocksRead)} cache hit</small></td><td>{formatLargeNumber(item.tuplesReturned || 0)} / {formatLargeNumber(item.tuplesFetched || 0)}</td><td>{formatLargeNumber(item.tuplesInserted || 0)} / {formatLargeNumber(item.tuplesUpdated || 0)} / {formatLargeNumber(item.tuplesDeleted || 0)}</td><td>{formatBytes(item.tempBytes || 0)}<small>{formatLargeNumber(item.tempFiles || 0)} dosya</small></td><td>{formatNumber(item.deadlocks || 0)}</td><td>{formatDuration((item.readTimeMs || 0) + (item.writeTimeMs || 0))}<small>read {formatDuration(item.readTimeMs || 0)} · write {formatDuration(item.writeTimeMs || 0)}</small></td></tr>)}</tbody></table></div>
          <div className="telemetry-subsection"><span className="panel-kicker">Cluster düzeyi · pg_stat_io</span><h3>I/O bağlamları</h3><p>Bu değerler veritabanına dağıtılmaz; PostgreSQL backend türü ve buffer bağlamı düzeyindedir.</p></div>
          <div className="database-health-table-wrap telemetry-table-wrap telemetry-scroll-table"><table className="database-health-table"><thead><tr><th>Backend / nesne</th><th>Bağlam</th><th>Okuma</th><th>Yazma</th><th>Writeback</th><th>Extend</th><th>Hit</th><th>Eviction / reuse</th><th>Fsync / toplam süre</th></tr></thead><tbody>{data.io.contexts.map((item, index) => <tr key={`${item.serverId}:${item.backendType}:${item.object}:${item.context}:${index}`}><td><span className="index-name"><strong>{item.backendType || '—'}</strong><small>{item.serverAlias || `server-${item.serverId || '—'}`} · {item.object || '—'}</small></span></td><td>{item.context || '—'}</td><td>{formatBytes(item.readBytes || 0)}<small>{formatLargeNumber(item.reads || 0)} işlem · {formatDuration(item.readTimeMs || 0)}</small></td><td>{formatBytes(item.writeBytes || 0)}<small>{formatLargeNumber(item.writes || 0)} işlem · {formatDuration(item.writeTimeMs || 0)}</small></td><td>{formatLargeNumber(item.writebacks || 0)}<small>{formatDuration(item.writebackTimeMs || 0)}</small></td><td>{formatBytes(item.extendBytes || 0)}<small>{formatLargeNumber(item.extends || 0)} işlem · {formatDuration(item.extendTimeMs || 0)}</small></td><td>{formatLargeNumber(item.hits || 0)}</td><td>{formatLargeNumber(item.evictions || 0)} / {formatLargeNumber(item.reuses || 0)}</td><td>{formatLargeNumber(item.fsyncs || 0)}<small>{formatDuration((item.fsyncTimeMs || 0) + (item.readTimeMs || 0) + (item.writeTimeMs || 0) + (item.writebackTimeMs || 0) + (item.extendTimeMs || 0))}</small></td></tr>)}</tbody></table></div>
          <div className="telemetry-subsection"><span className="panel-kicker">Sunucu düzeyi</span><h3>WAL, checkpoint ve bgwriter</h3></div>
          <div className="database-health-table-wrap telemetry-table-wrap"><table className="database-health-table"><thead><tr><th>Sunucu</th><th>WAL</th><th>WAL record / FPI</th><th>Checkpoint timed / requested</th><th>Checkpoint süre / buffer</th><th>Clean / backend / allocated</th><th>WAL write / sync</th></tr></thead><tbody>{data.io.servers.map((item, index) => <tr key={`${item.serverId}:${index}`}><td>{item.serverAlias || `server-${item.serverId || '—'}`}</td><td>{formatBytes(item.walBytes || 0)}<small>{formatLargeNumber(item.walBuffersFull || 0)} buffer-full</small></td><td>{formatLargeNumber(item.walRecords || 0)} / {formatLargeNumber(item.walFpi || 0)}</td><td>{formatLargeNumber(item.timedCheckpoints || 0)} / {formatLargeNumber(item.requestedCheckpoints || 0)}</td><td>{formatDuration((item.checkpointWriteTimeMs || 0) + (item.checkpointSyncTimeMs || 0))}<small>write {formatDuration(item.checkpointWriteTimeMs || 0)} · sync {formatDuration(item.checkpointSyncTimeMs || 0)} · {formatLargeNumber(item.checkpointBuffersWritten || 0)} buffer</small></td><td>{formatLargeNumber(item.buffersClean || 0)} / {formatLargeNumber(item.buffersBackend || 0)} / {formatLargeNumber(item.buffersAllocated || 0)}<small>maxwritten {formatLargeNumber(item.maxwrittenClean || 0)} · backend fsync {formatLargeNumber(item.buffersBackendFsync || 0)}</small></td><td>{formatLargeNumber(item.walWrites || 0)} / {formatLargeNumber(item.walSyncs || 0)}<small>{formatDuration((item.walWriteTimeMs || 0) + (item.walSyncTimeMs || 0))}</small></td></tr>)}</tbody></table></div>
        </> : <div className="telemetry-unavailable"><Info size={20} /><div><strong>I/O telemetrisi henüz kullanılamıyor</strong><p>{data.io.message || 'Collector yeterli örnek oluşturduğunda bu alan dolacak.'}</p></div></div>}
      </article>

      <article className="panel telemetry-panel">
        <div className="panel-heading"><div><span className="panel-kicker">Index geçmişi · {windowLabels[window]}</span><h2>Index kullanım sinyalleri</h2></div><span className="index-disclaimer"><Info size={13} /> DROP önerisi değildir</span></div>
        {data.indexes.available ? <>
          <p className="telemetry-caveat"><ShieldAlert size={15} /> Repository PK, unique ve constraint-backed index rollerini güvenilir biçimde ayıramaz. Sıfır tarama yalnız seçili penceredeki gözlemdir; silmeden önce daha uzun trafik, replica ve dönemsel işleri doğrulayın.</p>
          {indexSummary && <div className="index-summary"><span><b>{formatLargeNumber(indexSummary.indexesObserved)}</b> index izlendi</span><span><b>{formatLargeNumber(data.indexes.items.length)}</b> listede</span><span><b>{formatLargeNumber(indexSummary.candidateSignals)}</b> gözlemsel sinyal</span><span><b>{formatBytes(indexSummary.totalSizeBytes)}</b> toplam</span><span><b>{formatBytes(indexSummary.noScanSizeBytes)}</b> tarama gözlenmeyen alan</span></div>}
          <div className="database-health-table-wrap telemetry-table-wrap telemetry-scroll-table"><table className="database-health-table"><thead><tr><th>Index</th><th>Tablo</th><th>Boyut</th><th>Tarama / tuple</th><th>Blok read / hit</th><th>Son tarama</th><th>Sinyal / açıklama</th></tr></thead><tbody>{data.indexes.items.map((item) => <tr key={`${item.serverId}:${item.databaseId}:${item.indexId ?? item.indexName}`}><td><span className="index-name"><strong>{item.indexName}</strong><small>{item.serverAlias ? `${item.serverAlias} / ` : ''}{item.databaseName} · OID {item.indexId ?? '—'}</small></span></td><td><span className="index-name"><strong>{item.schemaName ? `${item.schemaName}.` : ''}{item.tableName}</strong><small>relation OID {item.relationId ?? '—'}</small></span></td><td>{formatBytes(item.indexSizeBytes)}</td><td>{formatLargeNumber(item.indexScans)}<small>read {formatLargeNumber(item.tuplesRead || 0)} · fetch {formatLargeNumber(item.tuplesFetched || 0)}</small></td><td>{formatLargeNumber(item.blocksRead || 0)} / {formatLargeNumber(item.blocksHit || 0)}<small>{formatCacheHit(item.blocksHit || 0, item.blocksRead || 0)} cache hit</small></td><td>{item.lastUsedAt ? formatDateTime(item.lastUsedAt) : 'Gözlenmedi'}</td><td><SeverityBadge severity={statusSeverity(item.signalLevel)} label={indexSignalLabel(item.signal || item.signalLevel)} />{item.recommendation && <small className="signal-detail">{item.recommendation}</small>}</td></tr>)}</tbody></table>{!data.indexes.items.length && <div className="empty-state"><Info size={26} /><strong>Index telemetrisi yok</strong><p>Seçili pencerede henüz index gözlemi oluşmadı.</p></div>}</div>
        </> : <div className="telemetry-unavailable"><Info size={20} /><div><strong>Index telemetrisi henüz kullanılamıyor</strong><p>{data.indexes.message || 'Collector yeterli örnek oluşturduğunda bu alan dolacak.'}</p></div></div>}
      </article>

      {data.collector.errors.length > 0 && <div className="error-panel collector-errors"><span className="error-panel-icon"><ShieldAlert size={24} /></span><div><strong>Collector uyarıları</strong>{data.collector.errors.map((error) => <p key={error}>{error}</p>)}</div></div>}
    </section>
  )
}

function Sidebar({ page, onNavigate, collapsed, onToggle, sourceName, connectionState }: { page: PageId; onNavigate: (page: PageId) => void; collapsed: boolean; onToggle: () => void; sourceName: string; connectionState: 'connected' | 'loading' | 'error' }) {
  return (
    <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
      <div className="brand-row">
        <button type="button" className="brand" onClick={() => onNavigate('overview')} aria-label="PG Advisor ana sayfa">
          <span className="brand-mark"><Database size={21} /><i /></span>
          <span className="brand-name"><strong>PG Advisor</strong><small>Performance intelligence</small></span>
        </button>
        <button type="button" className="sidebar-toggle" onClick={onToggle} aria-label={collapsed ? 'Menüyü genişlet' : 'Menüyü daralt'}><Menu size={18} /></button>
      </div>
      <nav aria-label="Ana menü">
        <span className="nav-label">Çalışma alanı</span>
        {navItems.map((item) => {
          const Icon = item.icon
          return <button type="button" key={item.id} className={page === item.id ? 'active' : ''} onClick={() => onNavigate(item.id)} aria-current={page === item.id ? 'page' : undefined} title={collapsed ? item.label : undefined}><span className="nav-icon"><Icon size={19} /></span><span className="nav-copy"><strong>{item.label}</strong><small>{item.description}</small></span>{page === item.id && <i className="active-indicator" />}</button>
        })}
      </nav>
      <div className="sidebar-footer">
        <div className={`connection-card ${connectionState}`}><span className="connection-icon"><Network size={17} /></span><div><strong>{sourceName}</strong><span><i /> {connectionState === 'connected' ? 'PoWA bağlı' : connectionState === 'loading' ? 'Bağlanıyor' : 'API erişilemiyor'}</span></div></div>
      </div>
    </aside>
  )
}

function App() {
  const [page, setPage] = useState<PageId>(getInitialPage)
  const [timeWindow, setTimeWindow] = useState<TimeWindow>('24h')
  const [collapsed, setCollapsed] = useState(false)
  const [selectedQuery, setSelectedQuery] = useState<string | null>(null)
  const [queryParams, setQueryParams] = useState<QueryListParams>({ page: 1, pageSize: 50, sort: 'impact' })
  const [overview, setOverview] = useState<Loadable<OverviewStats>>({ status: 'idle' })
  const [queries, setQueries] = useState<Loadable<ApiList<QuerySummary>>>({ status: 'idle' })
  const [health, setHealth] = useState<Loadable<SystemHealth>>({ status: 'idle' })
  const [operations, setOperations] = useState<Loadable<OperationsData>>({ status: 'idle' })

  const navigate = (next: PageId) => {
    setPage(next)
    window.history.replaceState(null, '', `#/${next}`)
    document.querySelector<HTMLElement>('#main-content')?.focus()
  }

  const errorMessage = (error: unknown) => {
    if (error instanceof ApiClientError) return error.status ? `${error.message} HTTP ${error.status}` : error.message
    return error instanceof Error ? error.message : 'Beklenmeyen bir hata oluştu.'
  }

  const loadOverview = () => {
    const controller = new AbortController(); setOverview({ status: 'loading' })
    advisorApi.getOverview(timeWindow, controller.signal).then(({ data }) => setOverview({ status: 'success', data })).catch((error) => { if (!controller.signal.aborted) setOverview({ status: 'error', error: errorMessage(error) }) })
    return controller
  }
  const loadQueries = () => {
    const controller = new AbortController(); setQueries({ status: 'loading' })
    advisorApi.getQueries(timeWindow, queryParams, controller.signal).then(({ data }) => setQueries({ status: 'success', data })).catch((error) => { if (!controller.signal.aborted) setQueries({ status: 'error', error: errorMessage(error) }) })
    return controller
  }
  const loadHealth = () => {
    const controller = new AbortController(); setHealth({ status: 'loading' })
    advisorApi.getSystemHealth(controller.signal).then(({ data }) => setHealth({ status: 'success', data })).catch((error) => { if (!controller.signal.aborted) setHealth({ status: 'error', error: errorMessage(error) }) })
    return controller
  }
  const loadOperations = () => {
    const controller = new AbortController(); setOperations({ status: 'loading' })
    advisorApi.getOperations(timeWindow, controller.signal).then(({ data }) => setOperations({ status: 'success', data })).catch((error) => { if (!controller.signal.aborted) setOperations({ status: 'error', error: errorMessage(error) }) })
    return controller
  }

  useEffect(() => {
    const controller = loadHealth()
    const onHashChange = () => setPage(getInitialPage())
    window.addEventListener('hashchange', onHashChange)
    return () => { controller.abort(); window.removeEventListener('hashchange', onHashChange) }
    // Sistem sağlığı pencere bağımsızdır ve ilk yüklemede hazırlanır.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const controllers = [loadOverview(), loadOperations()]
    return () => controllers.forEach((controller) => controller.abort())
    // Zaman aralığı değiştiğinde pencereye bağlı özet ve operasyon telemetrisi yenilenir.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [timeWindow])

  useEffect(() => {
    const controller = loadQueries()
    return () => controller.abort()
    // Sorgu filtresi veya zaman aralığı değiştiğinde sunucu tarafında yeni sayfa alınır.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [timeWindow, queryParams])

  const hasError = [overview, queries, health, operations].some((state) => state.status === 'error')
  const isConnecting = [overview, queries, health, operations].some((state) => state.status === 'loading' || state.status === 'idle')

  return (
    <div className={`app-shell ${collapsed ? 'sidebar-is-collapsed' : ''}`}>
      <a className="skip-link" href="#main-content">Ana içeriğe geç</a>
      <Sidebar page={page} onNavigate={navigate} collapsed={collapsed} onToggle={() => setCollapsed((value) => !value)} sourceName={overview.data?.databaseName || 'test-source · PoWA'} connectionState={hasError ? 'error' : isConnecting ? 'loading' : 'connected'} />
      <div className="app-main">
        <header className="topbar">
          <div className="mobile-brand"><span className="brand-mark"><Database size={18} /><i /></span><strong>PG Advisor</strong></div>
          <div className="breadcrumb"><span>PG Advisor</span><ChevronRight size={14} /><strong>{pageTitles[page]}</strong></div>
          <div className="topbar-actions">
            {page !== 'health' && <WindowPicker value={timeWindow} onChange={(nextWindow) => { setTimeWindow(nextWindow); setQueryParams((value) => ({ ...value, page: 1 })) }} />}
            <div className={`api-indicator ${demoModeEnabled ? 'demo' : hasError ? 'error' : isConnecting ? 'loading' : 'connected'}`} title={hasError ? 'Bazı API istekleri başarısız' : 'API bağlantı durumu'}>
              <i />{demoModeEnabled ? 'Demo modu' : hasError ? 'API sorunu' : isConnecting ? 'Bağlanıyor' : 'Canlı veri'}
            </div>
          </div>
        </header>
        {demoModeEnabled && <div className="demo-banner" role="status"><Info size={15} /><span><strong>Demo verisi gösteriliyor.</strong> Bu veri API hatası nedeniyle otomatik açılmadı; <code>VITE_DEMO_MODE=true</code> ile bilinçli olarak etkinleştirildi.</span></div>}
        <main id="main-content" tabIndex={-1}>
          {page === 'overview' && <OverviewPage state={overview} queries={queries.data} window={timeWindow} onRetry={loadOverview} onOpenQuery={setSelectedQuery} onNavigate={navigate} />}
          {page === 'queries' && <QueriesPage state={queries} params={queryParams} window={timeWindow} onParamsChange={setQueryParams} onRetry={loadQueries} onOpenQuery={setSelectedQuery} />}
          {page === 'health' && <SystemHealthPage state={health} onRetry={loadHealth} />}
          {page === 'operations' && <OperationsPage state={operations} window={timeWindow} onRetry={loadOperations} />}
        </main>
      </div>
      {selectedQuery && <QueryDetailModal queryId={selectedQuery} window={timeWindow} onClose={() => setSelectedQuery(null)} />}
    </div>
  )
}

export default App
