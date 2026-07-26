import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { CompositeIndexEvaluation, ExplainAnalyzePanel, highestBindParameter, parseExplainBindValues } from './App'
import type { CloneQueryEvaluationResult, CompositeIndexCandidate, QueryIndexAdvice } from './types'

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

describe('direct read-only EXPLAIN ANALYZE', () => {
  it('keeps the composite candidate operator readiness status unchanged', () => {
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

  it('shows a direct launcher and the exact positional bind requirement', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: "select * from orders where status = $1 and total > $2 and note = '$9' /* $8 */",
      state: { status: 'idle' },
      bindInput: '[]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('Clone’da EXPLAIN ANALYZE')
    expect(markup).toContain('$1–$2')
    expect(markup).toContain('Değerler saklanmaz')
    expect(markup).toContain('kaynak veritabanına dokunulmaz')
    expect(markup).not.toContain('disabled')
  })

  it('renders runtime metrics while keeping the raw plan lazy and closed', () => {
    const result: CloneQueryEvaluationResult = {
      status: 'RUNTIME_VALIDATED',
      reasonCode: 'READ_ONLY_QUERY_ANALYZED',
      message: 'Clone üzerinde ölçüldü.',
      queryId: '-42',
      validation: {
        mode: 'EXPLAIN_ANALYZE', statementClass: 'READ_ONLY_SELECT', planPreflight: 'READ_ONLY',
        transactionReadOnly: true, runnerPolicyRevision: 1, postgresVersion: '18.4',
        executionTimeMs: 12.5, planningTimeMs: .7, sharedHitBlocks: 20, sharedReadBlocks: 3,
        tempReadBlocks: 0, tempWrittenBlocks: 0, walRecords: 0, walBytes: 0,
        plan: { Plan: { 'Node Type': 'Seq Scan' } }, evaluatedAt: '2026-07-26T12:00:00Z',
      },
      executionTarget: 'DISPOSABLE_CLONE', sourceDdlExecuted: false, cloneDdlExecuted: false, cloneDestroyed: true,
    }
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select count(*) from orders',
      state: { status: 'success', data: result },
      bindInput: '[]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('EXPLAIN ANALYZE tamamlandı')
    expect(markup).toContain('Ham JSON planı')
    expect(markup).toContain('<details')
    expect(markup).not.toContain('&quot;Node Type&quot;: &quot;Seq Scan&quot;')
    expect(markup).toContain('sourceDdlExecuted=false')
    expect(markup).toContain('cloneDestroyed=true')
  })

  it('locks bind editing while a clone request is running', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select * from orders where id = $1',
      state: { status: 'loading' },
      bindInput: '[42]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('textarea')
    expect(markup).toContain('disabled')
    expect(markup).toContain('Clone hazırlanıyor…')
  })

  it('ignores placeholders in literals and comments and validates scalar arrays', () => {
    expect(highestBindParameter("select '$9', $$ $8 $$, value from t where a = $1 -- $7\n and b = $3")).toBe(3)
    expect(parseExplainBindValues('["paid", 10, null]', 3)).toEqual({ values: ['paid', 10, null] })
    expect(parseExplainBindValues('[{"unsafe": true}]', 1)).toEqual({ error: 'Her bind değeri string, number, boolean veya null olmalı.' })
    expect(parseExplainBindValues('[1]', 2)).toEqual({ error: 'Bu sorgu $1–$2 için tam 2 değer istiyor.' })
    expect(parseExplainBindValues('[9223372036854775807]', 1)).toEqual({ error: 'JavaScript güvenli integer sınırını aşan değerleri hassasiyet kaybını önlemek için JSON string olarak girin.' })
    expect(parseExplainBindValues('["9223372036854775807"]', 1)).toEqual({ values: ['9223372036854775807'] })
    expect(parseExplainBindValues('[]', 17)).toEqual({ error: 'Bu sorgu 17 bind değeri istiyor; güvenli arayüz sınırı 16.' })
    expect(parseExplainBindValues('not-json', 0)).toEqual({ values: [] })
  })

  it('uses PostgreSQL backslash rules for ordinary and E-prefixed strings', () => {
    expect(highestBindParameter("select 'abc\\', value from t where id = $2")).toBe(2)
    expect(highestBindParameter("select E'it\\'s $8', value from t where id = $2")).toBe(2)
  })
})
