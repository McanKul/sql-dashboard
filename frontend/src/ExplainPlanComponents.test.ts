import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { explainMetricPresentation, normalizeExplainPlan } from './explainPlan'
import { ExplainPlanInspector } from './components/explain/ExplainPlanInspector'
import { ExplainPlanNodeCard } from './components/explain/ExplainPlanNode'
import { ExplainPlanErrorBoundary } from './components/explain/ExplainPlanErrorBoundary'

function fixtureNode() {
  const plan = normalizeExplainPlan({
    Plan: {
      'Node Type': 'Index Scan', Schema: 'erp', 'Relation Name': 'orders', 'Index Name': 'orders_status_idx',
      'Actual Total Time': 12.5, 'Actual Rows': 250, 'Plan Rows': 25, 'Actual Loops': 2,
      'Shared Hit Blocks': 120, 'Shared Read Blocks': 8, 'Index Cond': '(status = $1)',
      Plans: [{ 'Node Type': 'Bitmap Index Scan', 'Actual Total Time': 2, 'Actual Rows': 25, 'Plan Rows': 25, 'Actual Loops': 1 }],
    },
    'Execution Time': 26,
  })
  if (!plan) throw new Error('component fixture should normalize')
  return { plan, node: plan.nodeById.get('0')! }
}

describe('visual EXPLAIN components', () => {
  it('renders a metric-rich accessible node card with a collapsible child count', () => {
    const { plan, node } = fixtureNode()
    const markup = renderToStaticMarkup(createElement(ExplainPlanNodeCard, {
      node,
      metric: 'rows',
      metricPresentation: explainMetricPresentation(node, 'rows', plan.nodeById.get(plan.rootId)!),
      collapsed: false,
      matched: true,
      direction: 'TB',
      selected: true,
      onToggle: vi.fn(),
    }))

    expect(markup).toContain('plan-node-card')
    expect(markup).toContain('selected')
    expect(markup).toContain('matched')
    expect(markup).toContain('Index Scan')
    expect(markup).toContain('erp.orders')
    expect(markup).toContain('orders_status_idx')
    expect(markup).toContain('10× eksik tahmin')
    expect(markup).toContain('aria-expanded="true"')
    expect(markup).toContain('Plan düğümü:')
  })

  it('renders selected-node conditions and measured buffer details without dumping JSON', () => {
    const { node } = fixtureNode()
    const markup = renderToStaticMarkup(createElement(ExplainPlanInspector, { node }))

    expect(markup).toContain('Seçili düğüm')
    expect(markup).toContain('Gerçek / tahmin')
    expect(markup).toContain('Shared hit / read')
    expect(markup).toContain('Index koşulu')
    expect(markup).toContain('(status = $1)')
    expect(markup).not.toContain('&quot;Node Type&quot;')
  })

  it('renders unavailable runtime evidence as N/A without an infinite estimate warning', () => {
    const plan = normalizeExplainPlan({ Plan: { 'Node Type': 'Seq Scan', 'Relation Name': 'orders', 'Plan Rows': 500 } })
    if (!plan) throw new Error('missing-metric fixture should normalize')
    const node = plan.nodeById.get(plan.rootId)!
    const card = renderToStaticMarkup(createElement(ExplainPlanNodeCard, {
      node,
      metric: 'rows',
      metricPresentation: explainMetricPresentation(node, 'rows', node),
      collapsed: false,
      matched: false,
      direction: 'TB',
      onToggle: vi.fn(),
    }))
    const inspector = renderToStaticMarkup(createElement(ExplainPlanInspector, { node }))

    expect(card).toContain('N/A')
    expect(card).not.toContain('∞')
    expect(inspector).toContain('Karşılaştırma yok')
    expect(inspector).toContain('Read time N/A')
  })

  it('defines a recoverable state for lazy visualization failures', () => {
    expect(ExplainPlanErrorBoundary.getDerivedStateFromError()).toEqual({ failed: true })
    const markup = renderToStaticMarkup(createElement(
      ExplainPlanErrorBoundary,
      {
        fallback: createElement('span', null, 'Ham JSON kullanılabilir'),
        children: createElement('span', null, 'Grafik hazır'),
      },
    ))
    expect(markup).toContain('Grafik hazır')
  })
})
