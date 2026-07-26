import { ChevronDown, ChevronRight, CircleGauge, Database, LoaderCircle, Network, Search, ShieldAlert, Sparkles } from 'lucide-react'
import { useState } from 'react'
import { advisorApi } from '../api'
import type { DatabaseOptimizeData, DatabaseOptimizeItem, QueryIndexAdvice, SourceCapability, TimeWindow } from '../types'
import { formatBytes, formatDuration, formatLargeNumber } from '../utils'

interface OptimizeState {
  status: 'idle' | 'loading' | 'error' | 'success'
  data?: DatabaseOptimizeData
  error?: string
}

type EvaluationState = { status: 'loading' } | { status: 'error'; message: string } | { status: 'success'; data: QueryIndexAdvice }

const capabilityEnabled = (capability?: SourceCapability) => capability?.status === 'AVAILABLE' && capability.available

export const completedHypopgEvaluation = (advice: QueryIndexAdvice): boolean => advice.status === 'VALIDATED' || advice.status === 'NO_IMPROVEMENT'

export const affectedQueryRemainder = (item: DatabaseOptimizeItem): number => Math.max(0, item.affectedQueryCount - item.affectedQueryIds.length)
export const affectedQueryRemainderLabel = (item: DatabaseOptimizeItem): string | null => {
  const remainder = affectedQueryRemainder(item)
  return remainder > 0 ? `+${formatLargeNumber(remainder)} sorgu` : null
}

export function existingIndexPresentation(item: DatabaseOptimizeItem, advice?: QueryIndexAdvice): { label: string; reason: string | null } {
  if (advice?.reasonCode === 'EQUIVALENT_INDEX_EXISTS') return { label: 'Örtüşme bulundu', reason: advice.message }
  return {
    label: item.existingIndex.status === 'NOT_CHECKED' ? 'Kontrol edilmedi' : item.existingIndex.status,
    reason: item.existingIndex.reason,
  }
}

export const displayedValidatedGroups = (persisted: number, sessionGroups: number): number => persisted + sessionGroups

function OptimizeRow({
  item,
  window,
  hypopgCapability,
  onOpenQuery,
  onValidated,
}: {
  item: DatabaseOptimizeItem
  window: TimeWindow
  hypopgCapability?: SourceCapability
  onOpenQuery: (id: string) => void
  onValidated: (groupId: string) => void
}) {
  const [expanded, setExpanded] = useState(false)
  const [evaluation, setEvaluation] = useState<EvaluationState | null>(null)
  const canEvaluate = capabilityEnabled(hypopgCapability)
  const queryKey = `${item.serverId}:${item.databaseId}:${item.representative.queryId}`

  const evaluate = async () => {
    if (!canEvaluate) return
    setEvaluation({ status: 'loading' })
    try {
      const { data } = await advisorApi.evaluateOptimizeGroup(item, window)
      setEvaluation({ status: 'success', data })
      if (completedHypopgEvaluation(data)) onValidated(item.groupId)
    } catch (error: unknown) {
      setEvaluation({ status: 'error', message: error instanceof Error ? error.message : 'HypoPG doğrulaması alınamadı.' })
    }
  }

  const evaluatedAdvice = evaluation?.status === 'success' ? evaluation.data : undefined
  const existingIndex = existingIndexPresentation(item, evaluatedAdvice)
  const affectedQueryOverflowLabel = affectedQueryRemainderLabel(item)

  return (
    <>
      <tr>
        <td><button type="button" className="optimize-expand" onClick={() => setExpanded((value) => !value)} aria-expanded={expanded}>{expanded ? <ChevronDown size={15} /> : <ChevronRight size={15} />}<span><strong>{item.schemaName}.{item.tableName}</strong><code>{item.columns.join(' → ')}</code></span></button></td>
        <td><strong>{formatLargeNumber(item.affectedQueryCount)}</strong><small>{formatDuration(item.affectedLoadMs)} etkilenen yük</small></td>
        <td><strong>{item.confidence === 'HIGH' ? 'Yüksek' : item.confidence === 'MEDIUM' ? 'Orta' : 'Düşük'}</strong><small>{formatLargeNumber(item.evidence.sampleCount)} snapshot</small></td>
        <td><strong>{existingIndex.label}</strong><small>{existingIndex.reason || '—'}</small></td>
        <td><strong>{item.maintenanceCost.risk}</strong><small>{item.maintenanceCost.writesPerHour == null ? 'Yazma hızı ölçülmedi' : `${formatLargeNumber(item.maintenanceCost.writesPerHour)} yazma/saat`} · WAL tahmini: —</small></td>
        <td><strong>{evaluation?.status === 'success' ? evaluation.data.status : item.hypopg.status}</strong><small>{evaluation?.status === 'error' ? evaluation.message : evaluation?.status === 'success' ? evaluation.data.message : item.hypopg.reason || '—'}</small></td>
        <td><button type="button" className="hypopg-button optimize-evaluate" disabled={!canEvaluate || evaluation?.status === 'loading'} onClick={evaluate} title={!canEvaluate ? hypopgCapability?.reason || 'HypoPG capability bilgisi alınamadı.' : undefined}>{evaluation?.status === 'loading' ? <LoaderCircle className="spin" size={14} /> : <Sparkles size={14} />} Doğrula</button></td>
      </tr>
      {expanded && <tr className="optimize-detail-row"><td colSpan={7}>
        <div className="optimize-detail-grid">
          <div><span>Aday SQL</span><pre><code>{item.createIndexSql}</code></pre></div>
          <div><span>Kanıt</span><strong>{formatLargeNumber(item.evidence.joinOccurrences)} JOIN · {formatLargeNumber(item.evidence.filterOccurrences)} WHERE</strong><small>{item.evidence.observedFrom} — {item.evidence.observedTo}</small></div>
          <div><span>Bakım maliyeti</span><strong>{item.maintenanceCost.writeRows == null ? 'Yazma satırı ölçülmedi' : `${formatLargeNumber(item.maintenanceCost.writeRows)} yazılan satır`}</strong><small>WAL tahmini: —{item.maintenanceCost.reason ? ` · ${item.maintenanceCost.reason}` : ''}</small></div>
        </div>
        <div className="affected-query-list"><span>Etkilenen sorgular</span>{item.affectedQueryIds.map((queryId) => <button type="button" key={queryId} onClick={() => onOpenQuery(`${item.serverId}:${item.databaseId}:${queryId}`)}><Search size={13} /> {queryId}</button>)}{affectedQueryOverflowLabel && <span>{affectedQueryOverflowLabel}</span>}<button type="button" onClick={() => onOpenQuery(queryKey)}><ChevronRight size={13} /> Temsilciyi aç</button></div>
      </td></tr>}
    </>
  )
}

export function DatabaseOptimizePage({ state, window, page, onPageChange, onRetry, onOpenQuery, hypopgCapability }: {
  state: OptimizeState
  window: TimeWindow
  page: number
  onPageChange: (page: number) => void
  onRetry: () => void
  onOpenQuery: (id: string) => void
  hypopgCapability?: SourceCapability
}) {
  const dataScopeKey = state.data ? `${window}:${state.data.scope.serverId ?? 'all'}:${state.data.scope.databaseId ?? 'all'}` : null
  const [validationSession, setValidationSession] = useState<{ scopeKey: string | null; groupIds: Set<string> }>(() => ({ scopeKey: null, groupIds: new Set() }))
  const sessionValidatedGroups = validationSession.scopeKey === dataScopeKey ? validationSession.groupIds.size : 0
  const recordValidation = (groupId: string) => {
    if (!dataScopeKey) return
    setValidationSession((current) => {
      const groupIds = current.scopeKey === dataScopeKey ? new Set(current.groupIds) : new Set<string>()
      groupIds.add(groupId)
      return { scopeKey: dataScopeKey, groupIds }
    })
  }

  if (state.status === 'idle' || state.status === 'loading') return <div className="loading-panel"><LoaderCircle className="spin" size={28} /><strong>Index adayları yükleniyor</strong></div>
  if (state.status === 'error') return <div className="error-panel"><ShieldAlert size={24} /><div><strong>Index adayları alınamadı</strong><p>{state.error}</p></div><button type="button" className="secondary-button" onClick={onRetry}>Yeniden dene</button></div>
  if (!state.data) return <div className="error-panel"><ShieldAlert size={24} /><div><strong>Index adayları alınamadı</strong></div><button type="button" className="secondary-button" onClick={onRetry}>Yeniden dene</button></div>
  const data = state.data
  const totalPages = Math.max(1, Math.ceil(data.total / data.pageSize))
  return (
    <section className="page-section optimize-page" aria-labelledby="optimize-title">
      <div className="page-heading"><div><span className="eyebrow">Database optimize · {window}</span><h1 id="optimize-title">Index adayları</h1><p>Benzer adaylar birleştirilir; yük değeri tasarruf tahmini değildir.</p></div><button type="button" className="secondary-button" onClick={onRetry}>Yenile</button></div>
      <div className="optimize-summary">
        <div><Database size={18} /><span>Aday grubu</span><strong>{formatLargeNumber(data.summary.candidateGroups)}</strong></div>
        <div><Network size={18} /><span>Etkilenen sorgu</span><strong>{formatLargeNumber(data.summary.affectedQueries)}</strong></div>
        <div><CircleGauge size={18} /><span>Etkilenen yük</span><strong>{formatDuration(data.summary.affectedLoadMs)}</strong></div>
        <div><Sparkles size={18} /><span>Doğrulanan grup</span><strong>{formatLargeNumber(displayedValidatedGroups(data.summary.validatedGroups, sessionValidatedGroups))}</strong></div>
      </div>
      {!capabilityEnabled(hypopgCapability) && <div className="capability-action-warning"><ShieldAlert size={16} /><span><strong>HypoPG kullanılamıyor.</strong> {hypopgCapability?.reason || 'Capability bilgisi alınamadı.'}</span></div>}
      <div className="optimize-table-wrap"><table className="optimize-table"><thead><tr><th>Aday</th><th>Sorgu / yük</th><th>Kanıt</th><th>Index örtüşmesi</th><th>Bakım riski</th><th>HypoPG</th><th><span className="sr-only">Aksiyon</span></th></tr></thead><tbody>{data.items.map((item) => <OptimizeRow key={item.groupId} item={item} window={window} hypopgCapability={hypopgCapability} onOpenQuery={onOpenQuery} onValidated={recordValidation} />)}</tbody></table>{!data.items.length && <div className="empty-state"><Database size={26} /><strong>Index adayı yok</strong><p>Seçili kapsam ve pencerede yeterli JOIN/WHERE kanıtı bulunmadı.</p></div>}</div>
      {data.total > data.pageSize && <div className="pagination"><button type="button" className="secondary-button" disabled={page <= 1} onClick={() => onPageChange(page - 1)}>Önceki</button><span>{page}. sayfa · {totalPages} sayfa</span><button type="button" className="secondary-button" disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Sonraki</button></div>}
    </section>
  )
}
