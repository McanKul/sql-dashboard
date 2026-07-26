import type { PostgresExplainDocument, PostgresExplainPlanNode } from './types'

export type ExplainMetricMode = 'duration' | 'rows' | 'io' | 'cost'
export type ExplainLayoutDirection = 'TB' | 'LR'
export type ExplainNodeSeverity = 'neutral' | 'info' | 'warning' | 'danger'

export interface ExplainCondition {
  label: string
  value: string
}

export interface ExplainMetricAvailability {
  actualLoops: boolean
  actualTime: boolean
  actualRows: boolean
  actualRowsTotal: boolean
  plannedRows: boolean
  estimateComparison: boolean
  cost: boolean
  buffers: boolean
  ioTiming: boolean
  rowsRemoved: boolean
  exclusiveTime: boolean
}

export interface NormalizedExplainNode {
  id: string
  parentId: string | null
  childIds: string[]
  depth: number
  nodeType: string
  parentRelationship: string | null
  relation: string | null
  schema: string | null
  alias: string | null
  indexName: string | null
  joinType: string | null
  parallelAware: boolean
  actualStartupTimeMs: number
  actualTotalTimeMs: number
  estimatedExclusiveTimeMs: number
  executionSharePercent: number
  exclusiveSharePercent: number
  actualRowsPerLoop: number
  actualRowsTotal: number
  plannedRowsPerLoop: number
  loops: number
  estimateFactor: number
  estimateDirection: 'under' | 'over' | 'exact'
  startupCost: number
  totalCost: number
  costSharePercent: number
  sharedHitBlocks: number
  sharedReadBlocks: number
  sharedDirtiedBlocks: number
  sharedWrittenBlocks: number
  tempReadBlocks: number
  tempWrittenBlocks: number
  ioReadTimeMs: number
  ioWriteTimeMs: number
  walRecords: number
  walBytes: number
  rowsRemoved: number
  availability: ExplainMetricAvailability
  conditions: ExplainCondition[]
  raw: PostgresExplainPlanNode
}

export interface ExplainPlanEdge {
  id: string
  source: string
  target: string
  relationship: string | null
}

export interface ExplainPlanHotspot {
  id: string
  nodeId: string
  kind: 'duration' | 'estimate' | 'temp' | 'filter'
  severity: 'warning' | 'danger'
  title: string
  detail: string
}

export interface NormalizedExplainPlan {
  rootId: string
  nodes: NormalizedExplainNode[]
  nodeById: Map<string, NormalizedExplainNode>
  edges: ExplainPlanEdge[]
  executionTimeMs: number
  planningTimeMs: number
  executionTimeAvailable: boolean
  planningTimeAvailable: boolean
  hotspots: ExplainPlanHotspot[]
}

export interface VisibleExplainPlan {
  nodes: NormalizedExplainNode[]
  edges: ExplainPlanEdge[]
  matchedIds: Set<string>
}

export interface ExplainMetricPresentation {
  label: string
  shortLabel: string
  percent: number
  severity: ExplainNodeSeverity
}

const conditionFields: Array<[keyof PostgresExplainPlanNode, string]> = [
  ['Index Cond', 'Index koşulu'],
  ['Filter', 'Filtre'],
  ['Recheck Cond', 'Recheck koşulu'],
  ['Hash Cond', 'Hash koşulu'],
  ['Merge Cond', 'Merge koşulu'],
  ['Join Filter', 'JOIN filtresi'],
]

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function finiteNumber(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function nullableText(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value : null
}

function safePercent(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 0
  return Math.min(100, value)
}

function estimateComparison(actualRows: number, plannedRows: number): Pick<NormalizedExplainNode, 'estimateFactor' | 'estimateDirection'> {
  if (actualRows === plannedRows) return { estimateFactor: 1, estimateDirection: 'exact' }
  if (plannedRows <= 0) return actualRows > 0
    ? { estimateFactor: Number.POSITIVE_INFINITY, estimateDirection: 'under' }
    : { estimateFactor: 1, estimateDirection: 'exact' }
  if (actualRows <= 0) return { estimateFactor: Number.POSITIVE_INFINITY, estimateDirection: 'over' }
  const ratio = actualRows / plannedRows
  return ratio > 1
    ? { estimateFactor: ratio, estimateDirection: 'under' }
    : { estimateFactor: 1 / ratio, estimateDirection: 'over' }
}

function extractConditions(node: PostgresExplainPlanNode): ExplainCondition[] {
  const conditions: ExplainCondition[] = []
  for (const [field, label] of conditionFields) {
    const value = node[field]
    if (typeof value === 'string' && value.trim()) conditions.push({ label, value })
  }
  return conditions
}

function displayRelation(node: PostgresExplainPlanNode): string | null {
  const relation = nullableText(node['Relation Name'])
  const schema = nullableText(node.Schema)
  if (!relation) return null
  return schema ? `${schema}.${relation}` : relation
}

/**
 * Turns PostgreSQL's recursive JSON plan into a stable, flat model. Traversal
 * and all later aggregation are iterative so very deep ERP plans cannot exhaust
 * the browser call stack.
 */
export function normalizeExplainPlan(input: unknown): NormalizedExplainPlan | null {
  const document = asRecord(input)
  const rawRoot = asRecord(document?.Plan)
  if (!document || !rawRoot || typeof rawRoot['Node Type'] !== 'string') return null

  type Pending = { raw: Record<string, unknown>; id: string; parentId: string | null; depth: number }
  const pending: Pending[] = [{ raw: rawRoot, id: '0', parentId: null, depth: 0 }]
  const nodes: NormalizedExplainNode[] = []
  const edges: ExplainPlanEdge[] = []

  while (pending.length > 0) {
    const current = pending.pop()
    if (!current) break
    const raw = current.raw as PostgresExplainPlanNode
    const actualLoopsAvailable = isFiniteNumber(raw['Actual Loops'])
    const actualRowsAvailable = isFiniteNumber(raw['Actual Rows'])
    const plannedRowsAvailable = isFiniteNumber(raw['Plan Rows'])
    const actualTimeAvailable = isFiniteNumber(raw['Actual Total Time']) && actualLoopsAvailable
    const costAvailable = isFiniteNumber(raw['Total Cost'])
    const bufferFields = [
      raw['Shared Hit Blocks'],
      raw['Shared Read Blocks'],
      raw['Shared Dirtied Blocks'],
      raw['Shared Written Blocks'],
      raw['Temp Read Blocks'],
      raw['Temp Written Blocks'],
    ]
    const removedFields = [
      raw['Rows Removed by Filter'],
      raw['Rows Removed by Join Filter'],
      raw['Rows Removed by Index Recheck'],
    ]
    const loops = Math.max(0, finiteNumber(raw['Actual Loops']))
    const actualRowsPerLoop = Math.max(0, finiteNumber(raw['Actual Rows']))
    const plannedRowsPerLoop = Math.max(0, finiteNumber(raw['Plan Rows']))
    const actualTotalTimeMs = Math.max(0, finiteNumber(raw['Actual Total Time'])) * loops
    const comparisonAvailable = actualRowsAvailable && plannedRowsAvailable
    const comparison = comparisonAvailable
      ? estimateComparison(actualRowsPerLoop, plannedRowsPerLoop)
      : { estimateFactor: 1, estimateDirection: 'exact' as const }
    const rowsRemovedPerLoop = removedFields.reduce<number>(
      (total, value) => total + Math.max(0, finiteNumber(value)),
      0,
    )
    const childRecords = Array.isArray(raw.Plans)
      ? raw.Plans.map(asRecord).filter((child): child is Record<string, unknown> => Boolean(child && typeof child['Node Type'] === 'string'))
      : []
    const childIds = childRecords.map((_child, index) => `${current.id}.${index}`)

    nodes.push({
      id: current.id,
      parentId: current.parentId,
      childIds,
      depth: current.depth,
      nodeType: raw['Node Type'],
      parentRelationship: nullableText(raw['Parent Relationship']),
      relation: displayRelation(raw),
      schema: nullableText(raw.Schema),
      alias: nullableText(raw.Alias),
      indexName: nullableText(raw['Index Name']),
      joinType: nullableText(raw['Join Type']),
      parallelAware: raw['Parallel Aware'] === true,
      actualStartupTimeMs: Math.max(0, finiteNumber(raw['Actual Startup Time'])) * loops,
      actualTotalTimeMs,
      estimatedExclusiveTimeMs: actualTotalTimeMs,
      executionSharePercent: 0,
      exclusiveSharePercent: 0,
      actualRowsPerLoop,
      actualRowsTotal: actualRowsPerLoop * loops,
      plannedRowsPerLoop,
      loops,
      ...comparison,
      startupCost: Math.max(0, finiteNumber(raw['Startup Cost'])),
      totalCost: Math.max(0, finiteNumber(raw['Total Cost'])),
      costSharePercent: 0,
      sharedHitBlocks: Math.max(0, finiteNumber(raw['Shared Hit Blocks'])),
      sharedReadBlocks: Math.max(0, finiteNumber(raw['Shared Read Blocks'])),
      sharedDirtiedBlocks: Math.max(0, finiteNumber(raw['Shared Dirtied Blocks'])),
      sharedWrittenBlocks: Math.max(0, finiteNumber(raw['Shared Written Blocks'])),
      tempReadBlocks: Math.max(0, finiteNumber(raw['Temp Read Blocks'])),
      tempWrittenBlocks: Math.max(0, finiteNumber(raw['Temp Written Blocks'])),
      ioReadTimeMs: Math.max(0, finiteNumber(raw['I/O Read Time'])),
      ioWriteTimeMs: Math.max(0, finiteNumber(raw['I/O Write Time'])),
      walRecords: Math.max(0, finiteNumber(raw['WAL Records'])),
      walBytes: Math.max(0, finiteNumber(raw['WAL Bytes'])),
      rowsRemoved: rowsRemovedPerLoop * loops,
      availability: {
        actualLoops: actualLoopsAvailable,
        actualTime: actualTimeAvailable,
        actualRows: actualRowsAvailable,
        actualRowsTotal: actualRowsAvailable && actualLoopsAvailable,
        plannedRows: plannedRowsAvailable,
        estimateComparison: comparisonAvailable,
        cost: costAvailable,
        buffers: bufferFields.some(isFiniteNumber),
        ioTiming: isFiniteNumber(raw['I/O Read Time']) || isFiniteNumber(raw['I/O Write Time']),
        rowsRemoved: removedFields.some(isFiniteNumber) && actualLoopsAvailable,
        exclusiveTime: actualTimeAvailable,
      },
      conditions: extractConditions(raw),
      raw,
    })

    if (current.parentId) {
      edges.push({
        id: `${current.parentId}->${current.id}`,
        source: current.parentId,
        target: current.id,
        relationship: nullableText(raw['Parent Relationship']),
      })
    }
    for (let index = childRecords.length - 1; index >= 0; index -= 1) {
      pending.push({ raw: childRecords[index], id: childIds[index], parentId: current.id, depth: current.depth + 1 })
    }
  }

  const nodeById = new Map(nodes.map((node) => [node.id, node]))
  const root = nodeById.get('0')
  if (!root) return null
  const documentExecutionTimeAvailable = isFiniteNumber(document['Execution Time'])
  const executionTimeAvailable = documentExecutionTimeAvailable || root.availability.actualTime
  const executionTimeMs = documentExecutionTimeAvailable
    ? Math.max(0, finiteNumber(document['Execution Time']))
    : root.actualTotalTimeMs
  const denominator = Math.max(executionTimeMs, root.actualTotalTimeMs, Number.EPSILON)
  const costDenominator = Math.max(root.totalCost, Number.EPSILON)

  for (let index = nodes.length - 1; index >= 0; index -= 1) {
    const node = nodes[index]
    let directChildrenTime = 0
    let everyChildTimeAvailable = true
    for (const childId of node.childIds) {
      const child = nodeById.get(childId)
      directChildrenTime += child?.actualTotalTimeMs ?? 0
      if (!child?.availability.actualTime) everyChildTimeAvailable = false
    }
    // Parallel branches can overlap and therefore sum above their parent. This
    // is an intentionally conservative approximation, never a negative value.
    node.availability.exclusiveTime = node.availability.actualTime && everyChildTimeAvailable
    node.estimatedExclusiveTimeMs = node.availability.exclusiveTime
      ? Math.max(0, node.actualTotalTimeMs - directChildrenTime)
      : 0
    node.executionSharePercent = node.availability.actualTime && executionTimeAvailable
      ? safePercent((node.actualTotalTimeMs / denominator) * 100)
      : 0
    node.exclusiveSharePercent = node.availability.exclusiveTime && executionTimeAvailable
      ? safePercent((node.estimatedExclusiveTimeMs / denominator) * 100)
      : 0
    node.costSharePercent = node.availability.cost && root.availability.cost
      ? safePercent((node.totalCost / costDenominator) * 100)
      : 0
  }

  const normalized: NormalizedExplainPlan = {
    rootId: '0',
    nodes,
    nodeById,
    edges,
    executionTimeMs,
    planningTimeMs: Math.max(0, finiteNumber(document['Planning Time'])),
    executionTimeAvailable,
    planningTimeAvailable: isFiniteNumber(document['Planning Time']),
    hotspots: [],
  }
  normalized.hotspots = findExplainHotspots(normalized)
  return normalized
}

function formatCompactNumber(value: number): string {
  if (!Number.isFinite(value)) return '∞'
  return new Intl.NumberFormat('tr-TR', { maximumFractionDigits: value >= 100 ? 0 : 1, notation: value >= 10_000 ? 'compact' : 'standard' }).format(value)
}

function hotspotCandidate(
  plan: NormalizedExplainPlan,
  predicate: (node: NormalizedExplainNode) => boolean,
  score: (node: NormalizedExplainNode) => number,
): NormalizedExplainNode | null {
  let candidate: NormalizedExplainNode | null = null
  let candidateScore = Number.NEGATIVE_INFINITY
  for (const node of plan.nodes) {
    if (!predicate(node)) continue
    const currentScore = score(node)
    if (currentScore > candidateScore) {
      candidate = node
      candidateScore = currentScore
    }
  }
  return candidate
}

export function findExplainHotspots(plan: NormalizedExplainPlan): ExplainPlanHotspot[] {
  const hotspots: ExplainPlanHotspot[] = []
  const duration = hotspotCandidate(
    plan,
    (node) => node.id !== plan.rootId && node.availability.exclusiveTime && node.exclusiveSharePercent >= 10,
    (node) => node.exclusiveSharePercent,
  )
  if (duration) hotspots.push({
    id: `duration:${duration.id}`,
    nodeId: duration.id,
    kind: 'duration',
    severity: duration.exclusiveSharePercent >= 30 ? 'danger' : 'warning',
    title: 'Süre yoğunluğu',
    detail: `${duration.nodeType}, yürütmenin yaklaşık %${formatCompactNumber(duration.exclusiveSharePercent)} kadarını kendi üzerinde harcıyor.`,
  })

  const estimate = hotspotCandidate(
    plan,
    (node) => node.availability.estimateComparison && node.estimateFactor >= 10,
    (node) => node.estimateFactor,
  )
  if (estimate) hotspots.push({
    id: `estimate:${estimate.id}`,
    nodeId: estimate.id,
    kind: 'estimate',
    severity: estimate.estimateFactor >= 100 ? 'danger' : 'warning',
    title: 'Satır tahmini sapması',
    detail: `${estimate.nodeType} için gerçek/tahmini satır farkı ${formatCompactNumber(estimate.estimateFactor)}×.`,
  })

  const temp = hotspotCandidate(
    plan,
    (node) => node.availability.buffers && node.tempReadBlocks + node.tempWrittenBlocks > 0,
    (node) => node.tempReadBlocks + node.tempWrittenBlocks,
  )
  if (temp) hotspots.push({
    id: `temp:${temp.id}`,
    nodeId: temp.id,
    kind: 'temp',
    severity: temp.tempReadBlocks + temp.tempWrittenBlocks >= 1_024 ? 'danger' : 'warning',
    title: 'Geçici disk kullanımı',
    detail: `${temp.nodeType} dalında ${formatCompactNumber(temp.tempReadBlocks + temp.tempWrittenBlocks)} temp blok hareketi görüldü.`,
  })

  if (hotspots.length < 3) {
    const filtered = hotspotCandidate(
      plan,
      (node) => node.availability.rowsRemoved
        && node.availability.actualRowsTotal
        && node.rowsRemoved > node.actualRowsTotal
        && node.rowsRemoved >= 100,
      (node) => node.rowsRemoved,
    )
    if (filtered) hotspots.push({
      id: `filter:${filtered.id}`,
      nodeId: filtered.id,
      kind: 'filter',
      severity: filtered.rowsRemoved >= 100_000 ? 'danger' : 'warning',
      title: 'Filtrede elenen satırlar',
      detail: `${filtered.nodeType} yaklaşık ${formatCompactNumber(filtered.rowsRemoved)} satırı sonradan eledi.`,
    })
  }
  return hotspots.slice(0, 3)
}

export function explainNodeSeverity(node: NormalizedExplainNode, mode: ExplainMetricMode, rootId = '0'): ExplainNodeSeverity {
  if (mode === 'duration' && !node.availability.exclusiveTime) return 'neutral'
  if (mode === 'rows' && !node.availability.estimateComparison) return 'neutral'
  if (mode === 'cost' && !node.availability.cost) return 'neutral'
  if (mode === 'io' && !node.availability.buffers) return 'neutral'
  if (node.id === rootId) return 'info'
  if (mode === 'duration') {
    if (node.exclusiveSharePercent >= 30) return 'danger'
    if (node.exclusiveSharePercent >= 10) return 'warning'
    return 'neutral'
  }
  if (mode === 'rows') {
    if (node.estimateFactor >= 100) return 'danger'
    if (node.estimateFactor >= 10) return 'warning'
    return 'neutral'
  }
  if (mode === 'cost') {
    if (node.costSharePercent >= 50) return 'danger'
    if (node.costSharePercent >= 20) return 'warning'
    return 'neutral'
  }
  const tempBlocks = node.tempReadBlocks + node.tempWrittenBlocks
  if (tempBlocks >= 1_024) return 'danger'
  if (tempBlocks > 0 || node.sharedReadBlocks > node.sharedHitBlocks) return 'warning'
  if (node.sharedReadBlocks > 0) return 'info'
  return 'neutral'
}

export function explainMetricPresentation(
  node: NormalizedExplainNode,
  mode: ExplainMetricMode,
  root: NormalizedExplainNode,
): ExplainMetricPresentation {
  if (mode === 'duration' && !node.availability.actualTime) return {
    label: 'Süre ölçülmedi',
    shortLabel: 'N/A',
    percent: 0,
    severity: 'neutral',
  }
  if (mode === 'duration') return {
    label: `${formatCompactNumber(node.actualTotalTimeMs)} ms dal süresi`,
    shortLabel: `%${formatCompactNumber(node.executionSharePercent)}`,
    percent: node.executionSharePercent,
    severity: explainNodeSeverity(node, mode, root.id),
  }
  if (mode === 'rows') {
    const actualRowsLabel = node.availability.actualRows ? formatCompactNumber(node.actualRowsPerLoop) : 'N/A'
    const plannedRowsLabel = node.availability.plannedRows ? formatCompactNumber(node.plannedRowsPerLoop) : 'N/A'
    if (!node.availability.estimateComparison) return {
      label: `${actualRowsLabel} gerçek / ${plannedRowsLabel} tahmin`,
      shortLabel: 'N/A',
      percent: 0,
      severity: 'neutral',
    }
    const factorLabel = Number.isFinite(node.estimateFactor) ? `${formatCompactNumber(node.estimateFactor)}×` : '∞'
    const percent = node.estimateFactor <= 1 ? 0 : Math.min(100, Math.log10(node.estimateFactor) * 33.34)
    return {
      label: `${formatCompactNumber(node.actualRowsPerLoop)} gerçek / ${formatCompactNumber(node.plannedRowsPerLoop)} tahmin`,
      shortLabel: node.estimateDirection === 'exact' ? 'eşleşti' : `${factorLabel} ${node.estimateDirection === 'under' ? 'eksik' : 'fazla'} tahmin`,
      percent,
      severity: explainNodeSeverity(node, mode, root.id),
    }
  }
  if (mode === 'cost' && !node.availability.cost) return {
    label: 'Planner cost ölçülmedi',
    shortLabel: 'N/A',
    percent: 0,
    severity: 'neutral',
  }
  if (mode === 'cost') return {
    label: `${formatCompactNumber(node.totalCost)} planner cost`,
    shortLabel: `%${formatCompactNumber(node.costSharePercent)} kök maliyeti`,
    percent: node.costSharePercent,
    severity: explainNodeSeverity(node, mode, root.id),
  }
  if (!node.availability.buffers) return {
    label: 'I/O metriği ölçülmedi',
    shortLabel: 'N/A',
    percent: 0,
    severity: 'neutral',
  }
  const blocks = node.sharedReadBlocks + node.tempReadBlocks + node.tempWrittenBlocks
  const rootBlocks = Math.max(1, root.sharedReadBlocks + root.tempReadBlocks + root.tempWrittenBlocks)
  return {
    label: `${formatCompactNumber(node.sharedHitBlocks)} hit / ${formatCompactNumber(node.sharedReadBlocks)} read`,
    shortLabel: node.tempReadBlocks + node.tempWrittenBlocks > 0 ? `${formatCompactNumber(node.tempReadBlocks + node.tempWrittenBlocks)} temp` : 'temp yok',
    percent: safePercent((blocks / rootBlocks) * 100),
    severity: explainNodeSeverity(node, mode, root.id),
  }
}

/** A log scale keeps both tiny and ERP-sized row flows legible. */
export function explainEdgeWidth(actualRowsTotal: number | null | undefined): number {
  if (actualRowsTotal == null) return 1.2
  if (!Number.isFinite(actualRowsTotal)) return actualRowsTotal > 0 ? 5 : 1.2
  const rows = Math.max(0, actualRowsTotal)
  return Math.min(5, 1.2 + Math.log10(rows + 1) * .65)
}

function ancestorIds(plan: NormalizedExplainPlan, nodeId: string): string[] {
  const ids: string[] = []
  let cursor = plan.nodeById.get(nodeId)?.parentId ?? null
  while (cursor) {
    ids.push(cursor)
    cursor = plan.nodeById.get(cursor)?.parentId ?? null
  }
  return ids
}

export const DEFAULT_EXPLAIN_VISIBLE_NODE_BUDGET = 30

export function defaultCollapsedExplainNodes(
  plan: NormalizedExplainPlan,
  visibleNodeBudget = DEFAULT_EXPLAIN_VISIBLE_NODE_BUDGET,
): Set<string> {
  const budget = Math.max(1, Math.floor(visibleNodeBudget))
  if (plan.nodes.length <= budget) return new Set()

  const preferredIds = new Set<string>()
  for (const hotspot of plan.hotspots) {
    preferredIds.add(hotspot.nodeId)
    for (const id of ancestorIds(plan, hotspot.nodeId)) preferredIds.add(id)
  }

  const collapsed = new Set<string>()
  const preferredQueue: string[] = [plan.rootId]
  const regularQueue: string[] = []
  let preferredCursor = 0
  let regularCursor = 0
  let visibleCount = 1

  while (preferredCursor < preferredQueue.length || regularCursor < regularQueue.length) {
    const nodeId = preferredCursor < preferredQueue.length
      ? preferredQueue[preferredCursor++]
      : regularQueue[regularCursor++]
    const node = plan.nodeById.get(nodeId)
    if (!node || node.childIds.length === 0) continue

    // A collapsed parent is the only safe representation for a very wide
    // fanout because leaf siblings cannot collapse themselves.
    if (visibleCount + node.childIds.length > budget) {
      collapsed.add(node.id)
      continue
    }

    visibleCount += node.childIds.length
    for (const childId of node.childIds) {
      if (preferredIds.has(childId)) preferredQueue.push(childId)
      else regularQueue.push(childId)
    }
  }
  return collapsed
}

export function collapsedExplainBranches(plan: NormalizedExplainPlan): Set<string> {
  return new Set(plan.nodes.filter((node) => node.childIds.length > 0).map((node) => node.id))
}

function nodeMatches(node: NormalizedExplainNode, query: string): boolean {
  const haystack = [node.nodeType, node.relation, node.alias, node.indexName, node.joinType, ...node.conditions.map((condition) => condition.value)]
    .filter(Boolean)
    .join(' ')
    .toLocaleLowerCase('tr')
  return haystack.includes(query)
}

export function visibleExplainPlan(
  plan: NormalizedExplainPlan,
  collapsedIds: ReadonlySet<string>,
  searchInput = '',
): VisibleExplainPlan {
  const search = searchInput.trim().toLocaleLowerCase('tr')
  const matchedIds = new Set<string>()
  const searchVisible = new Set<string>()
  if (search) {
    for (const node of plan.nodes) {
      if (!nodeMatches(node, search)) continue
      matchedIds.add(node.id)
      searchVisible.add(node.id)
      for (const id of ancestorIds(plan, node.id)) searchVisible.add(id)
    }
  }

  const visibleIds = new Set<string>()
  for (const node of plan.nodes) {
    if (search) {
      if (searchVisible.has(node.id)) visibleIds.add(node.id)
      continue
    }
    let hidden = false
    let parentId = node.parentId
    while (parentId) {
      if (collapsedIds.has(parentId)) {
        hidden = true
        break
      }
      parentId = plan.nodeById.get(parentId)?.parentId ?? null
    }
    if (!hidden) visibleIds.add(node.id)
  }

  return {
    nodes: plan.nodes.filter((node) => visibleIds.has(node.id)),
    edges: plan.edges.filter((edge) => visibleIds.has(edge.source) && visibleIds.has(edge.target)),
    matchedIds,
  }
}

export function isPostgresExplainDocument(value: unknown): value is PostgresExplainDocument {
  return normalizeExplainPlan(value) !== null
}
