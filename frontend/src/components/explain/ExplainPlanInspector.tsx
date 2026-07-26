import { AlertTriangle, Database, Filter, HardDrive, Rows3, Timer } from 'lucide-react'
import type { NormalizedExplainNode } from '../../explainPlan'
import { formatBytes, formatDuration, formatLargeNumber, formatNumber } from '../../utils'

function estimateLabel(node: NormalizedExplainNode): string {
  if (node.estimateDirection === 'exact') return 'Tahmin eşleşti'
  const factor = Number.isFinite(node.estimateFactor) ? `${formatNumber(node.estimateFactor)}×` : '∞'
  return `${factor} ${node.estimateDirection === 'under' ? 'eksik' : 'fazla'} tahmin`
}

function optionalText(value: unknown): string | null {
  if (typeof value === 'string') return value
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  if (Array.isArray(value)) return value.map(String).join(', ')
  return null
}

export function ExplainPlanInspector({ node }: { node: NormalizedExplainNode }) {
  const sortMethod = optionalText(node.raw['Sort Method'])
  const sortSpace = optionalText(node.raw['Sort Space Used'])
  const hashBatches = optionalText(node.raw['Hash Batches'])
  const peakMemory = optionalText(node.raw['Peak Memory Usage'])
  const actualRows = node.availability.actualRows ? formatLargeNumber(node.actualRowsPerLoop) : 'N/A'
  const plannedRows = node.availability.plannedRows ? formatLargeNumber(node.plannedRowsPerLoop) : 'N/A'
  const loops = node.availability.actualLoops ? formatLargeNumber(node.loops) : 'N/A'
  return (
    <aside className="plan-inspector" aria-label={`${node.nodeType} düğüm ayrıntıları`}>
      <div className="plan-inspector-heading">
        <div><span>Seçili düğüm</span><h4>{node.nodeType}</h4></div>
        <code>{node.id}</code>
      </div>
      {(node.relation || node.indexName) && (
        <div className="plan-inspector-object">
          <Database size={15} />
          <div><strong>{node.relation ?? node.alias}</strong>{node.indexName && <span>{node.indexName}</span>}</div>
        </div>
      )}

      <div className="plan-inspector-grid">
        <div><Timer size={14} /><span>Dal süresi</span><strong>{node.availability.actualTime ? formatDuration(node.actualTotalTimeMs) : 'N/A'}</strong><small>{node.availability.actualTime ? `%${formatNumber(node.executionSharePercent)} toplam` : 'Ölçüm yok'}</small></div>
        <div><Rows3 size={14} /><span>Gerçek / tahmin</span><strong>{actualRows} / {plannedRows}</strong><small>{node.availability.estimateComparison ? estimateLabel(node) : 'Karşılaştırma yok'}</small></div>
        <div><HardDrive size={14} /><span>Shared hit / read</span><strong>{node.availability.buffers ? `${formatLargeNumber(node.sharedHitBlocks)} / ${formatLargeNumber(node.sharedReadBlocks)}` : 'N/A'}</strong><small>{node.availability.ioTiming ? `${formatDuration(node.ioReadTimeMs)} read time` : 'Read time N/A'}</small></div>
        <div><Filter size={14} /><span>Elenen satır</span><strong>{node.availability.rowsRemoved ? formatLargeNumber(node.rowsRemoved) : 'N/A'}</strong><small>{loops} loop toplamı</small></div>
      </div>

      {node.conditions.length > 0 && (
        <section className="plan-inspector-section">
          <h5><Filter size={13} /> Koşullar</h5>
          {node.conditions.map((condition) => <div className="plan-condition" key={`${condition.label}:${condition.value}`}><span>{condition.label}</span><code>{condition.value}</code></div>)}
        </section>
      )}

      {(node.tempReadBlocks + node.tempWrittenBlocks > 0 || node.sharedDirtiedBlocks + node.sharedWrittenBlocks > 0) && (
        <section className="plan-inspector-section warning">
          <h5><AlertTriangle size={13} /> Yazma ve geçici alan</h5>
          <div className="plan-inspector-inline"><span>Temp read / write</span><strong>{formatLargeNumber(node.tempReadBlocks)} / {formatLargeNumber(node.tempWrittenBlocks)}</strong></div>
          <div className="plan-inspector-inline"><span>Shared dirtied / written</span><strong>{formatLargeNumber(node.sharedDirtiedBlocks)} / {formatLargeNumber(node.sharedWrittenBlocks)}</strong></div>
        </section>
      )}

      {(sortMethod || hashBatches || peakMemory) && (
        <section className="plan-inspector-section">
          <h5>Operator ayrıntıları</h5>
          {sortMethod && <div className="plan-inspector-inline"><span>Sort</span><strong>{sortMethod}{sortSpace ? ` · ${sortSpace} kB` : ''}</strong></div>}
          {hashBatches && <div className="plan-inspector-inline"><span>Hash batch</span><strong>{hashBatches}</strong></div>}
          {peakMemory && <div className="plan-inspector-inline"><span>Peak memory</span><strong>{peakMemory} kB</strong></div>}
        </section>
      )}

      {(node.walRecords > 0 || node.walBytes > 0) && <div className="plan-inspector-foot">WAL · {formatLargeNumber(node.walRecords)} kayıt · {formatBytes(node.walBytes)}</div>}
      <p className="plan-inspector-note">Düğüm süreleri loop toplamıdır. Elenen satırlar PostgreSQL’in loop ortalamasından yaklaşık toplamdır. “Kendi süresi” ve paralel dallardaki paylar yaklaşık değerdir; buffer sayıları alt dalları içerebilir.</p>
    </aside>
  )
}
