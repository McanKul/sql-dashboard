import { useEffect, useId, useMemo, useRef, useState } from 'react'
import {
  Activity,
  AlertCircle,
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
  OverviewStats,
  PageId,
  QueryDetail,
  QuerySummary,
  Severity,
  SystemHealth,
  TrendPoint,
} from './types'
import {
  chartPoints,
  formatDateTime,
  formatDuration,
  formatNumber,
  severityLabels,
} from './utils'
import './styles.css'

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
]

const pageTitles: Record<PageId, string> = {
  overview: 'Genel Bakış',
  queries: 'Sorgu Analizi',
  health: 'Sistem Sağlığı',
}

const getInitialPage = (): PageId => {
  const page = window.location.hash.replace('#/', '') as PageId
  return navItems.some((item) => item.id === page) ? page : 'overview'
}

function SeverityBadge({ severity, label }: { severity: Severity; label?: string }) {
  return <span className={`status-badge ${severity}`}><i aria-hidden="true" />{label ?? severityLabels[severity]}</span>
}

const queryImpactLabels: Record<Severity, string> = {
  critical: 'Kritik etki',
  warning: 'Orta/yüksek etki',
  healthy: 'Düşük etki',
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

function OverviewPage({ state, queries, onRetry, onOpenQuery, onNavigate }: {
  state: Loadable<OverviewStats>
  queries?: ApiList<QuerySummary>
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
      <PageHeading eyebrow={`${data.environment} · ${data.databaseName}`} title="Veritabanınız bugün nasıl?" description={`Son toplama ${formatDateTime(data.lastCollectedAt)} tarihinde tamamlandı.`}>
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
                    ? <span className={`change ${query.changePercent > 0 ? 'negative' : 'positive'}`}>{query.changePercent > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />}%{formatNumber(Math.abs(query.changePercent))}</span>
                    : <span className="change unavailable">Yeterli geçmiş yok</span>}
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

function QueriesPage({ state, onRetry, onOpenQuery }: {
  state: Loadable<ApiList<QuerySummary>>
  onRetry: () => void
  onOpenQuery: (id: string) => void
}) {
  const [search, setSearch] = useState('')
  const [severity, setSeverity] = useState<'all' | Severity>('all')
  const [sort, setSort] = useState<'impact' | 'regression' | 'latency'>('impact')

  const filtered = useMemo(() => {
    const items = [...(state.data?.items ?? [])]
    return items.filter((query) => {
      const term = search.trim().toLocaleLowerCase('tr')
      const matchesSearch = !term || `${query.title} ${query.sqlPreview} ${query.fingerprint} ${query.database}`.toLocaleLowerCase('tr').includes(term)
      return matchesSearch && (severity === 'all' || query.severity === severity)
    }).sort((a, b) => {
      if (sort === 'regression') return b.changePercent - a.changePercent
      if (sort === 'latency') return b.avgDurationMs - a.avgDurationMs
      return b.impactScore - a.impactScore
    })
  }, [search, severity, sort, state.data])

  if (state.status === 'loading' || state.status === 'idle') return <LoadingPanel label="Sorgular analiz ediliyor" />
  if (state.status === 'error' || !state.data) return <ErrorPanel message={state.error ?? 'Sorgu listesi alınamadı.'} onRetry={onRetry} />

  return (
    <section className="page-section" aria-labelledby="queries-title">
      <PageHeading eyebrow="Sorgu envanteri" title="Etkiyi bulun, nedeni anlayın" description={`${formatNumber(state.data.total)} benzersiz sorgu; toplam etkisine göre sıralanır.`} />

      <ReadingGuide>Etki puanı yükseldikçe sorgu daha önce incelenmelidir. Değişim değeri pozitifse sorgu önceki döneme göre yavaşlamış, negatifse hızlanmıştır.</ReadingGuide>

      <div className="query-toolbar" role="search">
        <label className="search-field"><Search size={18} aria-hidden="true" /><span className="sr-only">Sorgularda ara</span><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="SQL, sorgu kimliği veya veritabanı ara…" /></label>
        <label className="select-field"><span className="sr-only">Etki düzeyi</span><CircleDot size={15} /><select value={severity} onChange={(event) => setSeverity(event.target.value as typeof severity)}><option value="all">Tüm etki düzeyleri</option><option value="critical">Kritik etki</option><option value="warning">Orta-yüksek etki</option><option value="healthy">Düşük etki</option></select><ChevronDown size={14} /></label>
        <label className="select-field sort-field"><span>Sırala:</span><select value={sort} onChange={(event) => setSort(event.target.value as typeof sort)}><option value="impact">En yüksek etki</option><option value="regression">En çok yavaşlayan</option><option value="latency">En yüksek gecikme</option></select><ChevronDown size={14} /></label>
      </div>

      <div className="query-results-summary"><span><b>{filtered.length}</b> sonuç gösteriliyor</span>{(search || severity !== 'all') && <button type="button" onClick={() => { setSearch(''); setSeverity('all') }}>Filtreleri temizle <X size={13} /></button>}</div>

      <div className="query-table-card">
        <table className="query-table">
          <caption className="sr-only">Analiz edilen PostgreSQL sorguları</caption>
          <thead><tr><th scope="col">Sorgu</th><th scope="col">Etki</th><th scope="col">Ort. süre</th><th scope="col">Çağrı</th><th scope="col">Değişim</th><th scope="col"><span className="sr-only">Aç</span></th></tr></thead>
          <tbody>
            {filtered.map((query) => (
              <tr key={query.id} onClick={() => onOpenQuery(query.id)}>
                <td><button type="button" className="query-name-button" onClick={() => onOpenQuery(query.id)}><span><strong>{query.title}</strong><code>{query.sqlPreview}</code></span><small>{query.database} · {query.fingerprint}</small></button></td>
                <td><div className="table-score"><ImpactRing impact={query.impactScore} severity={query.severity} size="small" /><QueryImpactBadge severity={query.severity} /></div></td>
                <td><strong className="tabular">{formatDuration(query.avgDurationMs)}</strong><small>p/ çağrı</small></td>
                <td><strong className="tabular">{formatNumber(query.calls, true)}</strong><small>son 24 saat</small></td>
                <td>{query.hasComparison
                  ? <span className={`change ${query.changePercent > 0 ? 'negative' : 'positive'}`}>{query.changePercent > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />}%{formatNumber(Math.abs(query.changePercent))}</span>
                  : <span className="change unavailable">Yeterli geçmiş yok</span>}
                </td>
                <td><button type="button" className="icon-button row-open" onClick={() => onOpenQuery(query.id)} aria-label={`${query.title} detayını aç`}><ChevronRight size={17} /></button></td>
              </tr>
            ))}
          </tbody>
        </table>
        {!filtered.length && <div className="empty-state"><Search size={28} /><strong>Eşleşen sorgu yok</strong><p>Arama ifadesini veya filtreleri değiştirin.</p></div>}
      </div>
    </section>
  )
}

function QueryDetailModal({ queryId, onClose }: { queryId: string; onClose: () => void }) {
  const [state, setState] = useState<Loadable<QueryDetail>>({ status: 'loading' })
  const [copied, setCopied] = useState(false)
  const closeRef = useRef<HTMLButtonElement>(null)

  const load = () => {
    const controller = new AbortController()
    setState({ status: 'loading' })
    advisorApi.getQuery(queryId, controller.signal).then(({ data }) => {
      setState({ status: 'success', data })
    }).catch((error: unknown) => {
      if (error instanceof DOMException && error.name === 'AbortError') return
      setState({ status: 'error', error: error instanceof Error ? error.message : 'Sorgu detayı alınamadı.' })
    })
    return controller
  }

  useEffect(() => {
    const controller = load()
    closeRef.current?.focus()
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    document.addEventListener('keydown', onKeyDown)
    document.body.classList.add('modal-open')
    return () => {
      controller.abort()
      document.removeEventListener('keydown', onKeyDown)
      document.body.classList.remove('modal-open')
    }
    // queryId değiştiğinde yeni detay yüklenir; onClose kimliği modal ömründe sabittir.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [queryId])

  const copySql = async () => {
    if (!state.data) return
    await navigator.clipboard.writeText(state.data.fullSql)
    setCopied(true)
    window.setTimeout(() => setCopied(false), 1800)
  }

  const totalSharedBlocks = (state.data?.sharedBlocksHit ?? 0) + (state.data?.sharedBlocksRead ?? 0)
  const cacheHitPercent = totalSharedBlocks > 0 ? ((state.data?.sharedBlocksHit ?? 0) / totalSharedBlocks) * 100 : null

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
                <p>Pencerenin ilk örneği {formatDateTime(state.data.firstSeenAt)} · Son örnek {formatDateTime(state.data.lastSeenAt)}</p>
              </div>
              <div className="hero-score"><ImpactRing impact={state.data.impactScore} severity={state.data.severity} /><div><strong>Etki puanı</strong><span>Yükseldikçe inceleme önceliği artar</span></div></div>
            </div>

            <div className="modal-reading-guide">
              <ReadingGuide>Yüksek etki puanı önce bakılması gereken sorguyu, pozitif değişim ise yavaşlamayı gösterir. Shared blok okuması veya geçici yazma yükseliyorsa sorgu planını, bellek kullanımını ve veri erişim biçimini birlikte inceleyin.</ReadingGuide>
            </div>

            <div className="query-detail-layout">
              <main className="query-detail-main">
                <article className="detail-card sql-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Normalize edilmiş sorgu</span><h2>SQL</h2></div><button type="button" className="copy-sql-button" onClick={copySql}>{copied ? <Check size={15} /> : <Clipboard size={15} />}{copied ? 'Kopyalandı' : 'SQL’i kopyala'}</button></div>
                  <pre><code>{state.data.fullSql}</code></pre>
                </article>

                <article className="detail-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Son 24 saat</span><h2>Çalışma süresi eğilimi</h2></div>{state.data.hasComparison
                    ? <span className={`change ${state.data.changePercent > 0 ? 'negative' : 'positive'}`}>{state.data.changePercent > 0 ? <ArrowUpRight size={14} /> : <ArrowDownRight size={14} />} %{formatNumber(Math.abs(state.data.changePercent))}</span>
                    : <span className="change unavailable">Yeterli geçmiş yok</span>}
                  </div>
                  <MiniTrend points={state.data.trend.map((point) => ({ label: point.label.replace(' Tem', ''), value: point.durationMs }))} tone={!state.data.hasComparison ? 'blue' : state.data.changePercent > 0 ? 'red' : 'green'} height={142} label="Sorgunun son 24 saatteki çalışma süresi" />
                  <div className="trend-metrics"><div><span>Ortalama</span><strong>{formatDuration(state.data.avgDurationMs)}</strong></div><div><span>Çağrı</span><strong>{formatNumber(state.data.calls, true)}</strong></div><div><span>Okunan shared blok</span><strong>{formatNumber(state.data.sharedBlocksRead, true)}</strong></div><div><span>Toplam süre</span><strong>{formatDuration(state.data.totalTimeMs)}</strong></div></div>
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
                  </div> : <div className="comparison-unavailable"><Clock3 size={18} /><div><strong>Yeterli geçmiş yok</strong><p>Karşılaştırma için önceki dönemde en az 5 çağrı gerekir.</p></div></div>}
                </article>
              </main>

              <aside className="query-detail-aside">
                <article className="detail-card score-breakdown-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Puanlama modeli</span><h2>Etki kırılımı</h2></div></div>
                  <div className="score-breakdown-list">
                    {state.data.scoreBreakdown.map((item) => (
                      <div key={item.key} className="breakdown-item">
                        <div><strong>{item.label}</strong><span>{formatNumber(item.contribution)}/{item.maxContribution}</span></div>
                        <div className="breakdown-bar"><i style={{ width: `${item.maxContribution ? Math.min(100, (item.contribution / item.maxContribution) * 100) : 0}%` }} /></div>
                        <small>{item.hint}</small>
                      </div>
                    ))}
                  </div>
                </article>

                <article className="detail-card io-card">
                  <div className="detail-card-heading"><div><span className="panel-kicker">Buffer kullanımı</span><h2>I/O özeti</h2></div></div>
                  <div className="io-visual"><div style={{ '--hit-ratio': `${cacheHitPercent ?? 0}%` } as React.CSSProperties}><span /></div><strong>{cacheHitPercent === null ? '—' : `%${formatNumber(cacheHitPercent)}`}</strong><small>{cacheHitPercent === null ? 'ölçüm yok' : 'cache hit'}</small></div>
                  <div className="io-stats"><span><i className="hit" />Cache hit <b>{formatNumber(state.data.sharedBlocksHit, true)}</b></span><span><i className="read" />Okunan shared blok <b>{formatNumber(state.data.sharedBlocksRead, true)}</b></span></div>
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
        <div className="user-card"><span className="avatar">DB</span><div><strong>Advisor analisti</strong><small>SQL görüntüleme rolü</small></div></div>
      </div>
    </aside>
  )
}

function App() {
  const [page, setPage] = useState<PageId>(getInitialPage)
  const [collapsed, setCollapsed] = useState(false)
  const [selectedQuery, setSelectedQuery] = useState<string | null>(null)
  const [overview, setOverview] = useState<Loadable<OverviewStats>>({ status: 'idle' })
  const [queries, setQueries] = useState<Loadable<ApiList<QuerySummary>>>({ status: 'idle' })
  const [health, setHealth] = useState<Loadable<SystemHealth>>({ status: 'idle' })

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
    advisorApi.getOverview(controller.signal).then(({ data }) => setOverview({ status: 'success', data })).catch((error) => { if (!(error instanceof DOMException && error.name === 'AbortError')) setOverview({ status: 'error', error: errorMessage(error) }) })
    return controller
  }
  const loadQueries = () => {
    const controller = new AbortController(); setQueries({ status: 'loading' })
    advisorApi.getQueries(controller.signal).then(({ data }) => setQueries({ status: 'success', data })).catch((error) => { if (!(error instanceof DOMException && error.name === 'AbortError')) setQueries({ status: 'error', error: errorMessage(error) }) })
    return controller
  }
  const loadHealth = () => {
    const controller = new AbortController(); setHealth({ status: 'loading' })
    advisorApi.getSystemHealth(controller.signal).then(({ data }) => setHealth({ status: 'success', data })).catch((error) => { if (!(error instanceof DOMException && error.name === 'AbortError')) setHealth({ status: 'error', error: errorMessage(error) }) })
    return controller
  }

  useEffect(() => {
    const controllers = [loadOverview(), loadQueries(), loadHealth()]
    const onHashChange = () => setPage(getInitialPage())
    window.addEventListener('hashchange', onHashChange)
    return () => { controllers.forEach((controller) => controller.abort()); window.removeEventListener('hashchange', onHashChange) }
    // İlk yüklemede tüm panolar paralel hazırlanır.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const hasError = [overview, queries, health].some((state) => state.status === 'error')
  const isConnecting = [overview, queries, health].some((state) => state.status === 'loading' || state.status === 'idle')

  return (
    <div className={`app-shell ${collapsed ? 'sidebar-is-collapsed' : ''}`}>
      <a className="skip-link" href="#main-content">Ana içeriğe geç</a>
      <Sidebar page={page} onNavigate={navigate} collapsed={collapsed} onToggle={() => setCollapsed((value) => !value)} sourceName={overview.data?.databaseName || 'test-source · PoWA'} connectionState={hasError ? 'error' : isConnecting ? 'loading' : 'connected'} />
      <div className="app-main">
        <header className="topbar">
          <div className="mobile-brand"><span className="brand-mark"><Database size={18} /><i /></span><strong>PG Advisor</strong></div>
          <div className="breadcrumb"><span>PG Advisor</span><ChevronRight size={14} /><strong>{pageTitles[page]}</strong></div>
          <div className="topbar-actions">
            <div className={`api-indicator ${demoModeEnabled ? 'demo' : hasError ? 'error' : isConnecting ? 'loading' : 'connected'}`} title={hasError ? 'Bazı API istekleri başarısız' : 'API bağlantı durumu'}>
              <i />{demoModeEnabled ? 'Demo modu' : hasError ? 'API sorunu' : isConnecting ? 'Bağlanıyor' : 'Canlı veri'}
            </div>
          </div>
        </header>
        {demoModeEnabled && <div className="demo-banner" role="status"><Info size={15} /><span><strong>Demo verisi gösteriliyor.</strong> Bu veri API hatası nedeniyle otomatik açılmadı; <code>VITE_DEMO_MODE=true</code> ile bilinçli olarak etkinleştirildi.</span></div>}
        <main id="main-content" tabIndex={-1}>
          {page === 'overview' && <OverviewPage state={overview} queries={queries.data} onRetry={loadOverview} onOpenQuery={setSelectedQuery} onNavigate={navigate} />}
          {page === 'queries' && <QueriesPage state={queries} onRetry={loadQueries} onOpenQuery={setSelectedQuery} />}
          {page === 'health' && <SystemHealthPage state={health} onRetry={loadHealth} />}
        </main>
      </div>
      {selectedQuery && <QueryDetailModal queryId={selectedQuery} onClose={() => setSelectedQuery(null)} />}
    </div>
  )
}

export default App
