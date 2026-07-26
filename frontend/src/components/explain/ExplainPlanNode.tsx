import { memo } from 'react'
import { ArrowUpDown, ChevronDown, ChevronRight, Gauge, GitBranch, HardDrive, Network, Rows3, Search, Sigma, Timer } from 'lucide-react'
import { Handle, Position, type Node, type NodeProps } from '@xyflow/react'
import type { ExplainMetricMode, ExplainMetricPresentation, NormalizedExplainNode } from '../../explainPlan'
import { formatDuration, formatLargeNumber } from '../../utils'

export type ExplainPlanNodeData = {
  node: NormalizedExplainNode
  metric: ExplainMetricMode
  metricPresentation: ExplainMetricPresentation
  collapsed: boolean
  matched: boolean
  direction: 'TB' | 'LR'
  onToggle: (nodeId: string) => void
} & Record<string, unknown>

export type ExplainPlanFlowNode = Node<ExplainPlanNodeData, 'explainPlan'>

function metricIcon(mode: ExplainMetricMode) {
  if (mode === 'rows') return <Rows3 size={13} />
  if (mode === 'io') return <HardDrive size={13} />
  if (mode === 'cost') return <Gauge size={13} />
  return <Timer size={13} />
}

function nodeTypeIcon(nodeType: string) {
  if (nodeType.includes('Scan')) return <Search size={15} />
  if (nodeType.includes('Join') || nodeType.includes('Loop')) return <Network size={15} />
  if (nodeType.includes('Aggregate') || nodeType.includes('Group')) return <Sigma size={15} />
  if (nodeType.includes('Sort') || nodeType.includes('Incremental')) return <ArrowUpDown size={15} />
  return <GitBranch size={15} />
}

export function ExplainPlanNodeCard({
  node,
  metric,
  metricPresentation,
  collapsed,
  matched,
  selected = false,
  onToggle,
}: ExplainPlanNodeData & { selected?: boolean }) {
  const relationLabel = node.relation ?? node.alias
  const cardLabel = [node.nodeType, relationLabel, node.indexName].filter(Boolean).join(', ')
  const actualRows = node.availability.actualRows ? formatLargeNumber(node.actualRowsPerLoop) : 'N/A'
  const plannedRows = node.availability.plannedRows ? formatLargeNumber(node.plannedRowsPerLoop) : 'N/A'
  const loops = node.availability.actualLoops ? `${formatLargeNumber(node.loops)} loop` : 'N/A loop'
  const duration = node.availability.actualTime ? formatDuration(node.actualTotalTimeMs) : 'N/A'
  return (
    <article
      className={`plan-node-card severity-${metricPresentation.severity}${selected ? ' selected' : ''}${matched ? ' matched' : ''}`}
      aria-label={`Plan düğümü: ${cardLabel}. ${metricPresentation.label}.`}
    >
      <div className="plan-node-title">
        <span className="plan-node-icon">{nodeTypeIcon(node.nodeType)}</span>
        <div>
          <strong>{node.nodeType}</strong>
          {relationLabel && <span title={relationLabel}>{relationLabel}</span>}
        </div>
        {node.childIds.length > 0 && (
          <button
            type="button"
            className="plan-node-collapse nodrag nopan"
            onClick={(event) => { event.stopPropagation(); onToggle(node.id) }}
            aria-label={`${node.nodeType} alt dallarını ${collapsed ? 'aç' : 'kapat'}`}
            aria-expanded={!collapsed}
          >
            {collapsed ? <ChevronRight size={14} /> : <ChevronDown size={14} />}
            <span>{node.childIds.length}</span>
          </button>
        )}
      </div>

      <div className="plan-node-metric">
        <div><span>{metricIcon(metric)} {metricPresentation.label}</span><strong>{metricPresentation.shortLabel}</strong></div>
        <span className="plan-node-meter" aria-hidden="true"><i style={{ width: `${Math.max(2, metricPresentation.percent)}%` }} /></span>
      </div>

      <div className="plan-node-facts">
        <span title="Gerçek satır / planner tahmini"><Rows3 size={12} /> {actualRows} / {plannedRows}</span>
        <span title="Düğüm çalışma döngüsü">{loops}</span>
        <span title="Dalın toplam gerçek süresi"><Timer size={12} /> {duration}</span>
      </div>
      {(node.indexName || node.parentRelationship || node.parallelAware || node.tempReadBlocks + node.tempWrittenBlocks > 0) && (
        <div className="plan-node-tags">
          {node.parentRelationship && <span>{node.parentRelationship}</span>}
          {node.indexName && <span title={node.indexName}>index · {node.indexName}</span>}
          {node.parallelAware && <span>parallel</span>}
          {node.tempReadBlocks + node.tempWrittenBlocks > 0 && <span className="warning">temp I/O</span>}
        </div>
      )}
    </article>
  )
}

export const ExplainPlanNode = memo(function ExplainPlanNode(props: NodeProps<ExplainPlanFlowNode>) {
  const { data, selected } = props
  const isHorizontal = data.direction === 'LR'
  return (
    <>
      <Handle type="target" position={isHorizontal ? Position.Left : Position.Top} isConnectable={false} className="plan-node-handle" />
      <ExplainPlanNodeCard {...data} selected={selected} />
      <Handle type="source" position={isHorizontal ? Position.Right : Position.Bottom} isConnectable={false} className="plan-node-handle" />
    </>
  )
})
