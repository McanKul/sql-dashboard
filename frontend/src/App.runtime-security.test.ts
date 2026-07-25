import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { CompositeIndexEvaluation } from './App'
import type { CompositeIndexCandidate, QueryIndexAdvice } from './types'

const candidate: CompositeIndexCandidate = {
  candidateId: 'candidate-1', serverId: 1, databaseId: 2, queryId: '-42', relationId: 10,
  schemaName: 'public', tableName: 'orders', method: 'btree', columns: ['status', 'customer_id'],
  operatorOids: [96, 96], orderingRule: 'SELECTIVE_EQUALITY_FILTER_THEN_JOIN',
  joinOccurrences: 10, filterOccurrences: 10, rowsProcessed: 100, rowsFiltered: 80,
  sampleCount: 3, observedFrom: '2026-07-25T10:00:00Z', observedTo: '2026-07-25T11:00:00Z',
  confidence: 'HIGH', createIndexSql: 'CREATE INDEX idx ON public.orders (status, customer_id);',
  existingIndexChecked: true, runtimeFixtureAvailable: true, scoreIncluded: false,
}

const validatedAdvice: QueryIndexAdvice = {
  status: 'VALIDATED', reasonCode: 'COST_REDUCTION_CONFIRMED', message: 'Planner doğruladı.',
  candidate: {
    method: 'btree', columns: ['status', 'customer_id'],
    createIndexSql: candidate.createIndexSql, copyable: true,
  },
  ddlExecuted: false,
}

describe('runtime validation browser boundary', () => {
  it('shows fixture readiness without exposing a browser launch action', () => {
    const markup = renderToStaticMarkup(createElement(CompositeIndexEvaluation, {
      candidate,
      state: { status: 'success', data: validatedAdvice },
      copied: false,
      onEvaluate: vi.fn(),
      onCopy: vi.fn(),
    }))

    expect(markup).toContain('Operator doğrulamasına hazır')
    expect(markup).toContain('Operator API')
    expect(markup).toContain('disabled')
    expect(markup).not.toContain('Clone’da gerçek test')
  })
})
