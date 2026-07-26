import { describe, expect, it } from 'vitest'
import {
  collapsedExplainBranches,
  DEFAULT_EXPLAIN_VISIBLE_NODE_BUDGET,
  defaultCollapsedExplainNodes,
  explainEdgeWidth,
  explainMetricPresentation,
  explainNodeSeverity,
  normalizeExplainPlan,
  visibleExplainPlan,
} from './explainPlan'
import type { PostgresExplainDocument, PostgresExplainPlanNode } from './types'

const realisticPlan: PostgresExplainDocument = {
  Plan: {
    'Node Type': 'Hash Join',
    'Join Type': 'Inner',
    'Actual Startup Time': 3,
    'Actual Total Time': 100,
    'Actual Rows': 1_000,
    'Actual Loops': 1,
    'Plan Rows': 900,
    'Total Cost': 800,
    'Shared Hit Blocks': 1_200,
    'Shared Read Blocks': 300,
    'Hash Cond': '(orders.customer_id = customers.id)',
    Plans: [
      {
        'Node Type': 'Seq Scan',
        'Parent Relationship': 'Outer',
        Schema: 'erp',
        'Relation Name': 'orders',
        Alias: 'o',
        'Actual Total Time': 70,
        'Actual Rows': 10_000,
        'Actual Loops': 1,
        'Plan Rows': 100,
        'Total Cost': 480,
        'Rows Removed by Filter': 90_000,
        'Shared Hit Blocks': 800,
        'Shared Read Blocks': 280,
        Filter: "(status = 'paid')",
        'Extension Field': 'kept',
      },
      {
        'Node Type': 'Hash',
        'Parent Relationship': 'Inner',
        'Actual Total Time': 20,
        'Actual Rows': 500,
        'Actual Loops': 1,
        'Plan Rows': 500,
        'Total Cost': 200,
        'Hash Batches': 2,
        'Peak Memory Usage': 4_096,
        'Temp Written Blocks': 1_100,
        Plans: [{
          'Node Type': 'Index Only Scan',
          'Parent Relationship': 'Outer',
          Schema: 'erp',
          'Relation Name': 'customers',
          'Index Name': 'customers_pkey',
          'Actual Total Time': 10,
          'Actual Rows': 250,
          'Actual Loops': 2,
          'Plan Rows': 250,
          'Total Cost': 100,
          'Index Cond': '(id IS NOT NULL)',
          'Shared Hit Blocks': 400,
          'Shared Read Blocks': 20,
        }],
      },
    ],
  },
  'Planning Time': 1.25,
  'Execution Time': 105,
}

describe('PostgreSQL JSON plan normalization', () => {
  it('flattens nested nodes with stable path ids and parent relationships', () => {
    const plan = normalizeExplainPlan(realisticPlan)
    expect(plan).not.toBeNull()
    expect(plan?.nodes.map((node) => node.id)).toEqual(['0', '0.0', '0.1', '0.1.0'])
    expect(plan?.edges).toEqual([
      { id: '0->0.0', source: '0', target: '0.0', relationship: 'Outer' },
      { id: '0->0.1', source: '0', target: '0.1', relationship: 'Inner' },
      { id: '0.1->0.1.0', source: '0.1', target: '0.1.0', relationship: 'Outer' },
    ])
    expect(plan?.nodeById.get('0.0')).toMatchObject({ relation: 'erp.orders', alias: 'o', parentId: '0' })
    expect(plan?.planningTimeMs).toBe(1.25)
    expect(plan?.executionTimeMs).toBe(105)
  })

  it('turns loop-average time and rows into totals without losing raw extension fields', () => {
    const node = normalizeExplainPlan(realisticPlan)?.nodeById.get('0.1.0')
    expect(node).toMatchObject({
      actualTotalTimeMs: 20,
      actualRowsPerLoop: 250,
      actualRowsTotal: 500,
      plannedRowsPerLoop: 250,
      loops: 2,
      estimateFactor: 1,
      indexName: 'customers_pkey',
    })
    expect(normalizeExplainPlan(realisticPlan)?.nodeById.get('0.0')?.raw['Extension Field']).toBe('kept')
  })

  it('extracts conditions, buffers, temp usage, filtered rows, and estimate direction', () => {
    const plan = normalizeExplainPlan(realisticPlan)
    const scan = plan?.nodeById.get('0.0')
    expect(scan).toMatchObject({
      sharedHitBlocks: 800,
      sharedReadBlocks: 280,
      rowsRemoved: 90_000,
      estimateDirection: 'under',
      estimateFactor: 100,
      conditions: [{ label: 'Filtre', value: "(status = 'paid')" }],
    })
    expect(plan?.nodeById.get('0.1')).toMatchObject({ tempWrittenBlocks: 1_100 })
    expect(plan?.hotspots.map((hotspot) => hotspot.kind)).toEqual(expect.arrayContaining(['duration', 'estimate', 'temp']))
  })

  it('converts PostgreSQL per-loop rows-removed counters to a total', () => {
    const plan = normalizeExplainPlan({
      Plan: {
        'Node Type': 'Nested Loop',
        'Actual Rows': 3,
        'Plan Rows': 3,
        'Actual Total Time': 2,
        'Actual Loops': 25,
        'Rows Removed by Filter': 4,
        'Rows Removed by Join Filter': 2,
      },
    })
    const node = plan?.nodeById.get('0')

    expect(node?.rowsRemoved).toBe(150)
    expect(node?.availability.rowsRemoved).toBe(true)
    expect(plan?.hotspots.map((hotspot) => hotspot.kind)).toContain('filter')
  })

  it('keeps absent runtime metrics unavailable instead of inventing measured zeroes', () => {
    const plan = normalizeExplainPlan({
      Plan: {
        'Node Type': 'Result',
        'Plan Rows': 10,
        Plans: [{ 'Node Type': 'Seq Scan', 'Relation Name': 'orders', 'Plan Rows': 100 }],
      },
    })
    if (!plan) throw new Error('missing-metric fixture should normalize')
    const child = plan.nodeById.get('0.0')!
    const root = plan.nodeById.get(plan.rootId)!

    expect(child.availability).toMatchObject({
      actualLoops: false,
      actualTime: false,
      actualRows: false,
      actualRowsTotal: false,
      estimateComparison: false,
      buffers: false,
    })
    expect(plan.hotspots).toEqual([])
    expect(explainMetricPresentation(child, 'duration', root)).toMatchObject({ shortLabel: 'N/A', severity: 'neutral' })
    expect(explainMetricPresentation(child, 'rows', root)).toMatchObject({ label: 'N/A gerçek / 100 tahmin', shortLabel: 'N/A' })
    expect(explainMetricPresentation(child, 'io', root)).toMatchObject({ shortLabel: 'N/A', severity: 'neutral' })
    expect(explainEdgeWidth(null)).toBe(1.2)
  })

  it('handles zero estimates in both directions', () => {
    const underestimated = normalizeExplainPlan({ Plan: { 'Node Type': 'Result', 'Actual Rows': 5, 'Plan Rows': 0 } })?.nodeById.get('0')
    const overestimated = normalizeExplainPlan({ Plan: { 'Node Type': 'Result', 'Actual Rows': 0, 'Plan Rows': 5 } })?.nodeById.get('0')
    expect(underestimated?.estimateFactor).toBe(Number.POSITIVE_INFINITY)
    expect(underestimated?.estimateDirection).toBe('under')
    expect(overestimated?.estimateFactor).toBe(Number.POSITIVE_INFINITY)
    expect(overestimated?.estimateDirection).toBe('over')
  })

  it('clamps approximate exclusive time when parallel children overlap', () => {
    const plan = normalizeExplainPlan({
      Plan: {
        'Node Type': 'Gather', 'Actual Total Time': 10, 'Actual Loops': 1,
        Plans: [
          { 'Node Type': 'Parallel Seq Scan', 'Actual Total Time': 9, 'Actual Loops': 2 },
          { 'Node Type': 'Parallel Seq Scan', 'Actual Total Time': 8, 'Actual Loops': 2 },
        ],
      },
      'Execution Time': 12,
    })
    expect(plan?.nodeById.get('0')?.estimatedExclusiveTimeMs).toBe(0)
    expect(plan?.nodeById.get('0')?.exclusiveSharePercent).toBe(0)
  })

  it('rejects malformed documents and unknown-shaped roots without throwing', () => {
    expect(normalizeExplainPlan(null)).toBeNull()
    expect(normalizeExplainPlan({})).toBeNull()
    expect(normalizeExplainPlan({ Plan: { Plans: [] } })).toBeNull()
    expect(normalizeExplainPlan({ Plan: 'Seq Scan' })).toBeNull()
  })
})

describe('plan interaction model', () => {
  it('collapses descendants while keeping the branch node and its edge visible', () => {
    const plan = normalizeExplainPlan(realisticPlan)
    if (!plan) throw new Error('fixture should normalize')
    const visible = visibleExplainPlan(plan, new Set(['0.1']))
    expect(visible.nodes.map((node) => node.id)).toEqual(['0', '0.0', '0.1'])
    expect(visible.edges.map((edge) => edge.id)).toEqual(['0->0.0', '0->0.1'])
  })

  it('searches node, relation, index and condition text and reveals ancestors', () => {
    const plan = normalizeExplainPlan(realisticPlan)
    if (!plan) throw new Error('fixture should normalize')
    const byIndex = visibleExplainPlan(plan, collapsedExplainBranches(plan), 'customers_pkey')
    expect(byIndex.nodes.map((node) => node.id)).toEqual(['0', '0.1', '0.1.0'])
    expect(byIndex.matchedIds).toEqual(new Set(['0.1.0']))
    const byFilter = visibleExplainPlan(plan, new Set(), 'status')
    expect(byFilter.nodes.map((node) => node.id)).toEqual(['0', '0.0'])
  })

  it('maps duration, row error, I/O and planner cost to evidence-based severity', () => {
    const plan = normalizeExplainPlan(realisticPlan)
    if (!plan) throw new Error('fixture should normalize')
    const root = plan.nodeById.get('0')!
    const scan = plan.nodeById.get('0.0')!
    expect(explainNodeSeverity(scan, 'duration')).toBe('danger')
    expect(explainNodeSeverity(scan, 'rows')).toBe('danger')
    expect(explainNodeSeverity(scan, 'cost')).toBe('danger')
    expect(explainNodeSeverity(root, 'duration')).toBe('info')
    expect(explainMetricPresentation(scan, 'rows', root)).toMatchObject({ severity: 'danger', shortLabel: '100× eksik tahmin' })
    expect(explainMetricPresentation(scan, 'io', root).label).toContain('hit')
    expect(explainMetricPresentation(scan, 'cost', root)).toMatchObject({
      label: '480 planner cost', shortLabel: '%60 kök maliyeti', percent: 60, severity: 'danger',
    })
  })

  it('uses a bounded logarithmic edge width for actual row flow', () => {
    expect(explainEdgeWidth(-10)).toBe(1.2)
    expect(explainEdgeWidth(0)).toBe(1.2)
    expect(explainEdgeWidth(10)).toBeGreaterThan(explainEdgeWidth(1))
    expect(explainEdgeWidth(10_000)).toBeGreaterThan(explainEdgeWidth(10))
    expect(explainEdgeWidth(1_000_000_000)).toBe(5)
    expect(explainEdgeWidth(Number.POSITIVE_INFINITY)).toBe(5)
  })

  it('does not label a sequential scan as bad without measured evidence', () => {
    const plan = normalizeExplainPlan({ Plan: { 'Node Type': 'Seq Scan', 'Relation Name': 'tiny', 'Actual Total Time': .01, 'Actual Rows': 3, 'Plan Rows': 3, 'Actual Loops': 1 } })
    const node = plan?.nodeById.get('0')
    expect(node && explainNodeSeverity(node, 'rows')).toBe('info')
  })

  it('uses a compact default only for large plans and never truncates nodes', () => {
    const root: PostgresExplainPlanNode = { 'Node Type': 'Result', 'Actual Loops': 1 }
    let cursor = root
    for (let index = 1; index <= 600; index += 1) {
      const child: PostgresExplainPlanNode = { 'Node Type': `Result ${index}`, 'Actual Loops': 1 }
      cursor.Plans = [child]
      cursor = child
    }
    const plan = normalizeExplainPlan({ Plan: root })
    expect(plan?.nodes).toHaveLength(601)
    expect(plan?.nodeById.get(`0${'.0'.repeat(600)}`)?.nodeType).toBe('Result 600')
    if (!plan) throw new Error('deep fixture should normalize')
    const collapsed = defaultCollapsedExplainNodes(plan)
    expect(collapsed.size).toBeGreaterThan(0)
    const compact = visibleExplainPlan(plan, collapsed)
    expect(compact.nodes.length).toBeLessThan(plan.nodes.length)
    expect(visibleExplainPlan(plan, new Set()).nodes).toHaveLength(601)
  })

  it('keeps a 500-way fanout inside the initial visible-node budget', () => {
    const root: PostgresExplainPlanNode = {
      'Node Type': 'Append',
      'Actual Loops': 1,
      Plans: Array.from({ length: 500 }, (_value, index) => ({
        'Node Type': 'Seq Scan',
        'Relation Name': `erp_partition_${index}`,
        'Actual Loops': 1,
      })),
    }
    const plan = normalizeExplainPlan({ Plan: root })
    if (!plan) throw new Error('wide fixture should normalize')

    expect(plan.nodes).toHaveLength(501)
    const collapsed = defaultCollapsedExplainNodes(plan)
    expect(collapsed).toContain(plan.rootId)
    expect(visibleExplainPlan(plan, collapsed).nodes.length).toBeLessThanOrEqual(DEFAULT_EXPLAIN_VISIBLE_NODE_BUDGET)
    expect(visibleExplainPlan(plan, collapsedExplainBranches(plan)).nodes).toHaveLength(1)
    expect(visibleExplainPlan(plan, new Set()).nodes).toHaveLength(501)
  })
})
