import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { CompositeIndexEvaluation, ExplainAnalyzePanel, highestBindParameter, parseExplainBindValues } from './App'
import type { QueryExplainAnalyzeResult, CompositeIndexCandidate, QueryIndexAdvice, SourceCapability } from './types'

const sourceExplainCapability: SourceCapability = {
  key: 'sourceExplain', label: 'Source EXPLAIN', status: 'AVAILABLE', configured: true,
  healthy: true, dataAvailable: true, available: true, reasonCode: 'AVAILABLE', reason: 'Kullanılabilir.',
}

const unavailableHypopgCapability: SourceCapability = {
  key: 'hypopg', label: 'HypoPG', status: 'NOT_CONFIGURED', configured: false,
  healthy: null, dataAvailable: null, available: false, reasonCode: 'TARGET_NOT_CONFIGURED',
  reason: 'Bu veritabanı evaluator hedefi değil.',
}

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

    expect(markup).toContain('Clone doğrulamasına hazır')
    expect(markup).toContain('Operator API')
    expect(markup).toContain('disabled')
    expect(markup).not.toContain('Clone’da gerçek test')
  })

  it('keeps an unsupported HypoPG action visible but disabled with its reason', () => {
    const markup = renderToStaticMarkup(createElement(CompositeIndexEvaluation, {
      candidate,
      copied: false,
      onEvaluate: vi.fn(),
      onCopy: vi.fn(),
      capability: unavailableHypopgCapability,
    }))

    expect(markup).toContain('Composite adayı doğrula')
    expect(markup).toContain('disabled')
    expect(markup).toContain('Bu veritabanı evaluator hedefi değil.')
  })

  it('shows a direct launcher and the exact positional bind requirement', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: "select * from orders where status = $1 and total > $2 and note = '$9' /* $8 */",
      state: { status: 'idle' },
      bindInput: '[]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
      capability: sourceExplainCapability,
    }))

    expect(markup).toContain("Ana DB&#x27;de EXPLAIN ANALYZE")
    expect(markup).toContain('$1–$2')
    expect(markup).toContain('Bind değerleri advisor’a kaydedilmez')
    expect(markup).toContain('kaynak log politikası geçerlidir')
    expect(markup).toContain('Ana veritabanında gerçek yük oluşturur. Yalnız SELECT.')
    expect(markup).not.toContain('disabled')
  })

  it('renders runtime metrics while keeping the raw plan lazy and closed', () => {
    const result: QueryExplainAnalyzeResult = {
      status: 'RUNTIME_VALIDATED',
      reasonCode: 'READ_ONLY_QUERY_ANALYZED',
      message: 'Clone üzerinde ölçüldü.',
      queryId: '-42',
      validation: {
        mode: 'EXPLAIN_ANALYZE', statementClass: 'READ_ONLY_SELECT', planPreflight: 'READ_ONLY',
        transactionReadOnly: true, safetyPolicyRevision: 1, postgresVersion: '18.4', executionRole: 'advisor_explain', databaseId: 2,
        executionTimeMs: 12.5, planningTimeMs: .7, sharedHitBlocks: 20, sharedReadBlocks: 3,
        tempReadBlocks: 0, tempWrittenBlocks: 0, walRecords: 0, walBytes: 0,
        plan: { Plan: { 'Node Type': 'Seq Scan', 'Relation Name': 'orders', 'Actual Total Time': 12, 'Actual Rows': 40, 'Plan Rows': 10, 'Actual Loops': 1 } }, evaluatedAt: '2026-07-26T12:00:00Z',
      },
      executionTarget: 'SOURCE_DATABASE', sourceExecuted: true, sourceDdlExecuted: false, transactionRolledBack: true,
    }
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select count(*) from orders',
      state: { status: 'success', data: result },
      bindInput: '[]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('EXPLAIN ANALYZE tamamlandı')
    expect(markup).toContain('Etkileşimli yürütme planı')
    expect(markup).toContain('Ham JSON planı')
    expect(markup).toContain('<details')
    expect(markup).not.toContain('&quot;Node Type&quot;: &quot;Seq Scan&quot;')
    expect(markup).toContain('sourceDdlExecuted=false')
    expect(markup).toContain('Kaynak sorgu çalıştırıldı')
    expect(markup).toContain('Transaction geri alındı')
  })

  it('locks bind editing while a source request is running', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select * from orders where id = $1',
      state: { status: 'loading' },
      bindInput: '[42]',
      onBindInput: vi.fn(),
      onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('textarea')
    expect(markup).toContain('disabled')
    expect(markup).toContain('Kaynakta çalışıyor…')
  })

  it('does not claim source execution or rollback when the backend cannot attest them', () => {
    const result: QueryExplainAnalyzeResult = {
      status: 'UNAVAILABLE', reasonCode: 'SOURCE_UNREACHABLE', message: 'Kaynak bağlantısı kurulamadı.', queryId: '-42', validation: null,
      executionTarget: 'SOURCE_DATABASE', sourceExecuted: null, sourceDdlExecuted: false, transactionRolledBack: null,
    }
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select 1', state: { status: 'success', data: result }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('Kaynak yürütme durumu doğrulanamadı')
    expect(markup).toContain('Rollback durumu doğrulanamadı')
    expect(markup).not.toContain('sourceExecuted=false')
    expect(markup).not.toContain('transactionRolledBack=false')
  })

  it('renders a confirmed non-execution and unnecessary rollback as neutral facts', () => {
    const result: QueryExplainAnalyzeResult = {
      status: 'UNSAFE', reasonCode: 'SELECT_ONLY', message: 'Yalnız SELECT.', queryId: '-42', validation: null,
      executionTarget: 'SOURCE_DATABASE', sourceExecuted: false, sourceDdlExecuted: false, transactionRolledBack: false,
    }
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'delete from orders', state: { status: 'success', data: result }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('class="neutral"')
    expect(markup).toContain('Kaynak sorgu çalıştırılmadı')
    expect(markup).toContain('Rollback gerekmedi')
    expect(markup).not.toContain('Rollback başarısız')
  })

  it('warns when an executed source transaction cannot be rolled back', () => {
    const result: QueryExplainAnalyzeResult = {
      status: 'UNAVAILABLE', reasonCode: 'SOURCE_ROLLBACK_FAILED', message: 'Rollback başarısız.', queryId: '-42', validation: null,
      executionTarget: 'SOURCE_DATABASE', sourceExecuted: true, sourceDdlExecuted: false, transactionRolledBack: false,
    }
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select * from orders', state: { status: 'success', data: result }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
    }))

    expect(markup).toContain('class="warning"')
    expect(markup).toContain('Kaynak sorgu çalıştırıldı')
    expect(markup).toContain('Rollback başarısız')
  })

  it('ignores placeholders in literals and comments and validates scalar arrays', () => {
    expect(highestBindParameter("select '$9', $$ $8 $$, value from t where a = $1 -- $7\n and b = $3")).toBe(3)
    expect(parseExplainBindValues('["paid", 10, null]', 3)).toEqual({ values: ['paid', 10, null] })
    expect(parseExplainBindValues('[{"unsafe": true}]', 1)).toEqual({ error: 'Her bind değeri string, number, boolean veya null olmalı.' })
    expect(parseExplainBindValues('[1]', 2)).toEqual({ error: 'Bu sorgu $1–$2 için tam 2 değer istiyor.' })
    expect(parseExplainBindValues('[9223372036854775807]', 1)).toEqual({ error: 'JavaScript güvenli integer sınırını aşan değerleri hassasiyet kaybını önlemek için JSON string olarak girin.' })
    expect(parseExplainBindValues('["9223372036854775807"]', 1)).toEqual({ values: ['9223372036854775807'] })
    expect(parseExplainBindValues('[]', 129)).toEqual({ error: 'Bu sorgu 129 bind değeri istiyor; kaynak EXPLAIN sınırı 128.' })
    expect(parseExplainBindValues('not-json', 0)).toEqual({ values: [] })
  })

  it('accepts 128 source binds and rejects a 129th value or payloads over 64 KiB', () => {
    const values128 = Array.from({ length: 128 }, (_value, index) => index)
    const values129 = [...values128, 128]
    expect(parseExplainBindValues(JSON.stringify(values128), 128)).toEqual({ values: values128 })
    expect(parseExplainBindValues(JSON.stringify(values129), 128)).toEqual({ error: 'En fazla 128 bind değeri gönderebilirsiniz.' })

    const below64KiB = Array.from({ length: 31 }, () => 'x'.repeat(2_048))
    const above64KiB = Array.from({ length: 32 }, () => 'x'.repeat(2_048))
    expect(parseExplainBindValues(JSON.stringify(below64KiB), 31)).toEqual({ values: below64KiB })
    expect(parseExplainBindValues(JSON.stringify(above64KiB), 32)).toEqual({ error: 'Bind değerlerinin toplam boyutu 64 KiB sınırını aşıyor.' })
  })

  it('keeps the launcher enabled through bind 128 and disables it at bind 129', () => {
    const renderForCount = (count: number) => renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: `select ${Array.from({ length: count }, (_value, index) => `$${index + 1}`).join(', ')}`,
      state: { status: 'idle' }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
      capability: sourceExplainCapability,
    }))
    const atLimit = renderForCount(128)
    const overLimit = renderForCount(129)

    expect(atLimit).toContain('$1–$128')
    expect(atLimit).toContain('en fazla 128 değer ve toplam 64 KiB')
    expect(atLimit).not.toContain('disabled')
    expect(overLimit).toContain('kaynak EXPLAIN sınırı 128')
    expect(overLimit).toContain('disabled')
  })

  it('keeps source EXPLAIN visible but disabled when the selected database is not configured', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select 1', state: { status: 'idle' }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
      capability: { ...sourceExplainCapability, status: 'NOT_CONFIGURED', available: false, configured: false, reason: 'Bu veritabanı evaluator hedefi değil.' },
    }))
    expect(markup).toContain('Source EXPLAIN kullanılamıyor')
    expect(markup).toContain('Bu veritabanı evaluator hedefi değil.')
    expect(markup).toContain('disabled')
  })

  it('keeps the error retry path under the same source capability gate', () => {
    const markup = renderToStaticMarkup(createElement(ExplainAnalyzePanel, {
      statement: 'select 1', state: { status: 'error', error: 'Evaluator geçici olarak kapalı.' }, bindInput: '[]', onBindInput: vi.fn(), onEvaluate: vi.fn(),
      capability: { ...sourceExplainCapability, status: 'UNREACHABLE', available: false, healthy: false, reason: 'Evaluator erişilemiyor.' },
    }))
    expect(markup).toContain('Evaluator geçici olarak kapalı.')
    expect(markup).toContain('Evaluator erişilemiyor.')
    expect(markup.match(/disabled/g)?.length).toBeGreaterThanOrEqual(2)
  })

  it('uses PostgreSQL backslash rules for ordinary and E-prefixed strings', () => {
    expect(highestBindParameter("select 'abc\\', value from t where id = $2")).toBe(2)
    expect(highestBindParameter("select E'it\\'s $8', value from t where id = $2")).toBe(2)
  })
})
