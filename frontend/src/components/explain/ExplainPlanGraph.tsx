import { useCallback, useEffect, useMemo, useState } from 'react'
import dagre from '@dagrejs/dagre'
import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  useReactFlow,
  type Edge,
} from '@xyflow/react'
import '@xyflow/react/dist/style.css'
import { AlertTriangle, ChevronsDownUp, ChevronsUpDown, Gauge, HardDrive, Rows3, Search, Timer } from 'lucide-react'
import {
  collapsedExplainBranches,
  defaultCollapsedExplainNodes,
  explainEdgeWidth,
  explainMetricPresentation,
  normalizeExplainPlan,
  visibleExplainPlan,
  type ExplainLayoutDirection,
  type ExplainMetricMode,
  type ExplainPlanHotspot,
  type NormalizedExplainPlan,
} from '../../explainPlan'
import { ExplainPlanInspector } from './ExplainPlanInspector'
import { ExplainPlanNode, type ExplainPlanFlowNode } from './ExplainPlanNode'

const nodeWidth = 296
const nodeHeight = 184
const nodeTypes = { explainPlan: ExplainPlanNode }

function layoutElements(
  plan: NormalizedExplainPlan,
  visible: ReturnType<typeof visibleExplainPlan>,
  metric: ExplainMetricMode,
  direction: ExplainLayoutDirection,
  collapsedIds: ReadonlySet<string>,
  onToggle: (nodeId: string) => void,
): { nodes: ExplainPlanFlowNode[]; edges: Edge[] } {
  const graph = new dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}))
  graph.setGraph({
    rankdir: direction,
    ranksep: direction === 'TB' ? 62 : 78,
    nodesep: direction === 'TB' ? 30 : 26,
    marginx: 28,
    marginy: 28,
  })
  for (const node of visible.nodes) graph.setNode(node.id, { width: nodeWidth, height: nodeHeight })
  for (const edge of visible.edges) graph.setEdge(edge.source, edge.target)
  dagre.layout(graph)

  const root = plan.nodeById.get(plan.rootId)
  if (!root) return { nodes: [], edges: [] }
  return {
    nodes: visible.nodes.map((node) => {
      const position = graph.node(node.id) as { x: number; y: number }
      return {
        id: node.id,
        type: 'explainPlan',
        position: { x: position.x - nodeWidth / 2, y: position.y - nodeHeight / 2 },
        draggable: false,
        selectable: true,
        focusable: true,
        ariaLabel: `${node.nodeType}${node.relation ? `, ${node.relation}` : ''}`,
        data: {
          node,
          metric,
          metricPresentation: explainMetricPresentation(node, metric, root),
          collapsed: collapsedIds.has(node.id),
          matched: visible.matchedIds.has(node.id),
          direction,
          onToggle,
        },
      }
    }),
    edges: visible.edges.map((edge) => {
      const target = plan.nodeById.get(edge.target)
      const rowFlowAvailable = target?.availability.actualRowsTotal === true
      return {
        id: edge.id,
        source: edge.source,
        target: edge.target,
        type: 'smoothstep',
        selectable: false,
        focusable: false,
        label: edge.relationship && !['Outer', 'Inner'].includes(edge.relationship) ? edge.relationship : undefined,
        ariaLabel: `${target?.nodeType ?? 'alt düğüm'} bağlantısı${rowFlowAvailable ? '' : ', satır akışı ölçülmedi'}`,
        style: {
          stroke: '#b9c4da',
          strokeDasharray: rowFlowAvailable ? undefined : '4 4',
          strokeWidth: explainEdgeWidth(rowFlowAvailable ? target.actualRowsTotal : null),
        },
        labelStyle: { fill: '#7c879c', fontSize: 11, fontWeight: 650 },
        labelBgStyle: { fill: '#f8faff', fillOpacity: .92 },
      }
    }),
  }
}

function ViewportSync({ signature }: { signature: string }) {
  const { fitView } = useReactFlow<ExplainPlanFlowNode>()
  useEffect(() => {
    const handle = globalThis.setTimeout(() => { void fitView({ padding: .16, duration: 260, maxZoom: 1 }) }, 0)
    return () => globalThis.clearTimeout(handle)
  }, [fitView, signature])
  return null
}

function hotspotIcon(kind: ExplainPlanHotspot['kind']) {
  if (kind === 'estimate') return <Rows3 size={15} />
  if (kind === 'temp') return <HardDrive size={15} />
  if (kind === 'filter') return <AlertTriangle size={15} />
  return <Timer size={15} />
}

export function ExplainPlanGraph({ plan }: { plan: unknown }) {
  const model = useMemo(() => normalizeExplainPlan(plan), [plan])
  const [metric, setMetric] = useState<ExplainMetricMode>('duration')
  const [direction, setDirection] = useState<ExplainLayoutDirection>('TB')
  const [collapsedIds, setCollapsedIds] = useState<Set<string>>(() => model ? defaultCollapsedExplainNodes(model) : new Set())
  const [selectedId, setSelectedId] = useState('0')
  const [search, setSearch] = useState('')

  useEffect(() => {
    if (!model) return
    setCollapsedIds(defaultCollapsedExplainNodes(model))
    setSelectedId(model.rootId)
    setSearch('')
  }, [model])

  const toggleNode = useCallback((nodeId: string) => {
    setSelectedId((current) => current.startsWith(`${nodeId}.`) ? nodeId : current)
    setCollapsedIds((current) => {
      const next = new Set(current)
      if (next.has(nodeId)) next.delete(nodeId)
      else next.add(nodeId)
      return next
    })
  }, [])

  const revealAndSelect = useCallback((nodeId: string) => {
    if (!model) return
    setSearch('')
    setCollapsedIds((current) => {
      const next = new Set(current)
      let parentId = model.nodeById.get(nodeId)?.parentId ?? null
      while (parentId) {
        next.delete(parentId)
        parentId = model.nodeById.get(parentId)?.parentId ?? null
      }
      return next
    })
    setSelectedId(nodeId)
  }, [model])

  const visible = useMemo(
    () => model ? visibleExplainPlan(model, collapsedIds, search) : null,
    [collapsedIds, model, search],
  )
  const layoutedElements = useMemo(
    () => model && visible
      ? layoutElements(model, visible, metric, direction, collapsedIds, toggleNode)
      : { nodes: [], edges: [] },
    [collapsedIds, direction, metric, model, toggleNode, visible],
  )
  const elements = useMemo(() => ({
    nodes: layoutedElements.nodes.map((node) => ({ ...node, selected: node.id === selectedId })),
    edges: layoutedElements.edges,
  }), [layoutedElements, selectedId])
  const selectedNode = model?.nodeById.get(selectedId) ?? model?.nodeById.get(model?.rootId ?? '')
  const viewportSignature = `${direction}:${metric}:${elements.nodes.map((node) => node.id).join(',')}`

  if (!model) return (
    <div className="plan-visualizer-empty" role="status">
      <AlertTriangle size={18} />
      <div><strong>Plan ağacı çözümlenemedi</strong><span>Ham JSON planı aşağıdaki bölümden inceleyebilirsiniz.</span></div>
    </div>
  )

  return (
    <section className="plan-visualizer" aria-label="Etkileşimli PostgreSQL yürütme planı">
      <div className="plan-visualizer-heading">
        <div><span className="panel-kicker">{model.nodes.length} plan düğümü</span><h3>Etkileşimli yürütme planı</h3></div>
        <span className="plan-visualizer-hint">Düğüme tıklayın · kaydırarak yakınlaştırın</span>
      </div>

      {model.hotspots.length > 0 ? (
        <div className="plan-hotspots" role="group" aria-label="Plan hotspot özeti">
          {model.hotspots.map((hotspot) => (
            <button
              type="button"
              key={hotspot.id}
              className={`plan-hotspot ${hotspot.severity}`}
              onClick={() => revealAndSelect(hotspot.nodeId)}
            >
              {hotspotIcon(hotspot.kind)}
              <span><strong>{hotspot.title}</strong><small>{hotspot.detail}</small></span>
            </button>
          ))}
        </div>
      ) : <div className="plan-no-hotspot"><span>Belirgin hotspot yok</span><small>Bu tek çalışmada güçlü süre, tahmin veya temp I/O sapması görülmedi.</small></div>}

      <div className="plan-toolbar">
        <div className="plan-segment" role="group" aria-label="Plan metriği">
          <button type="button" aria-pressed={metric === 'duration'} className={metric === 'duration' ? 'active' : ''} onClick={() => setMetric('duration')}><Timer size={13} /> Süre</button>
          <button type="button" aria-pressed={metric === 'rows'} className={metric === 'rows' ? 'active' : ''} onClick={() => setMetric('rows')}><Rows3 size={13} /> Satır</button>
          <button type="button" aria-pressed={metric === 'io'} className={metric === 'io' ? 'active' : ''} onClick={() => setMetric('io')}><HardDrive size={13} /> I/O</button>
          <button type="button" aria-pressed={metric === 'cost'} className={metric === 'cost' ? 'active' : ''} onClick={() => setMetric('cost')}><Gauge size={13} /> Cost</button>
        </div>
        <label className="plan-search"><Search size={13} /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Node, tablo veya index ara" aria-label="Plan düğümlerinde ara" /></label>
        <div className="plan-segment compact" role="group" aria-label="Plan yönü">
          <button type="button" aria-label="Planı dikey göster" aria-pressed={direction === 'TB'} className={direction === 'TB' ? 'active' : ''} onClick={() => setDirection('TB')}>TB</button>
          <button type="button" aria-label="Planı yatay göster" aria-pressed={direction === 'LR'} className={direction === 'LR' ? 'active' : ''} onClick={() => setDirection('LR')}>LR</button>
        </div>
        <div className="plan-tree-actions" role="group" aria-label="Plan dalı görünürlüğü">
          <button type="button" onClick={() => setCollapsedIds(new Set())} title="Tüm plan dallarını aç"><ChevronsUpDown size={14} /> Tümünü aç</button>
          <button type="button" onClick={() => {
            setCollapsedIds(collapsedExplainBranches(model))
            setSelectedId(model.rootId)
          }} title="Kökün altındaki dalları kapat"><ChevronsDownUp size={14} /> Toparla</button>
        </div>
      </div>

      <div className="plan-workspace">
        <div className="plan-canvas" role="region" aria-label={`${elements.nodes.length} / ${model.nodes.length} plan düğümü görünür`}>
          {elements.nodes.length > 0 ? (
            <ReactFlow<ExplainPlanFlowNode>
              nodes={elements.nodes}
              edges={elements.edges}
              nodeTypes={nodeTypes}
              onNodeClick={(_event, node) => setSelectedId(node.id)}
              nodesDraggable={false}
              nodesConnectable={false}
              elementsSelectable
              edgesFocusable={false}
              deleteKeyCode={null}
              fitView
              fitViewOptions={{ padding: .16, maxZoom: 1 }}
              minZoom={.12}
              maxZoom={1.55}
              proOptions={{ hideAttribution: true }}
              ariaLabelConfig={{
                'controls.zoomIn.ariaLabel': 'Yakınlaştır',
                'controls.zoomOut.ariaLabel': 'Uzaklaştır',
                'controls.fitView.ariaLabel': 'Planı ekrana sığdır',
                'minimap.ariaLabel': 'Plan mini haritası',
              }}
            >
              <Background color="#dce3ef" gap={22} size={1} />
              <Controls showInteractive={false} />
              {model.nodes.length > 12 && <MiniMap<ExplainPlanFlowNode> pannable zoomable nodeColor={(node) => {
                const severity = node.data.metricPresentation.severity
                if (severity === 'danger') return '#d85a67'
                if (severity === 'warning') return '#e8a84c'
                if (severity === 'info') return '#7187e8'
                return '#aeb9cc'
              }} />}
              <ViewportSync signature={viewportSignature} />
            </ReactFlow>
          ) : <div className="plan-search-empty"><Search size={18} /><span>“{search}” ile eşleşen plan düğümü yok.</span></div>}
        </div>
        {selectedNode && <ExplainPlanInspector node={selectedNode} />}
      </div>
      <div className="plan-legend" aria-label="Plan renk açıklaması"><span className="danger">Yüksek sapma</span><span className="warning">İncelenmeli</span><span className="info">Kök / I/O</span><small>{elements.nodes.length} / {model.nodes.length} düğüm görünür</small></div>
    </section>
  )
}
