import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { CapabilityMatrix } from './components/capabilities/CapabilityMatrix'
import {
  affectedQueryRemainder,
  affectedQueryRemainderLabel,
  completedHypopgEvaluation,
  DatabaseOptimizePage,
  displayedValidatedGroups,
  existingIndexPresentation,
} from './pages/DatabaseOptimizePage'
import { demoCapabilities, demoDatabaseOptimize } from './demoData'
import type { QueryIndexAdvice } from './types'

describe('product UX components', () => {
  it('shows healthy capabilities compactly and explains only unavailable states', () => {
    const rows = structuredClone(demoCapabilities.items)
    rows[0].capabilities[1] = { ...rows[0].capabilities[1], status: 'NOT_CONFIGURED', available: false, reason: 'Extension kurulmamış.' }
    const markup = renderToStaticMarkup(createElement(CapabilityMatrix, { rows }))
    expect(markup).toContain('Kullanılabilir')
    expect(markup).toContain('Yapılandırılmadı')
    expect(markup).toContain('Extension kurulmamış.')
    expect(markup).not.toContain('Kullanılabilir.</small>')
  })

  it('labels aggregate workload honestly and disables one-shot HypoPG when unsupported', () => {
    const hypopg = { ...demoCapabilities.items[0].capabilities.find((item) => item.key === 'hypopg')!, status: 'NOT_CONFIGURED' as const, available: false, reason: 'Evaluator hedefi değil.' }
    const markup = renderToStaticMarkup(createElement(DatabaseOptimizePage, {
      state: { status: 'success', data: demoDatabaseOptimize }, window: '24h', page: 1,
      onPageChange: vi.fn(), onRetry: vi.fn(), onOpenQuery: vi.fn(), hypopgCapability: hypopg,
    }))
    expect(markup).toContain('Etkilenen yük')
    expect(markup).toContain('tasarruf tahmini değildir')
    expect(markup).toContain('Evaluator hedefi değil.')
    expect(markup).toContain('disabled')
    expect(markup).toContain('WAL tahmini: —')
  })

  it('calculates a bounded affected-query preview without hiding the exact remainder', () => {
    const data = structuredClone(demoDatabaseOptimize)
    data.items[0].affectedQueryCount = 25
    data.items[0].affectedQueryIds = ['901', '902']
    expect(affectedQueryRemainder(data.items[0])).toBe(23)
    expect(affectedQueryRemainderLabel(data.items[0])).toBe('+23 sorgu')
  })

  it('counts completed HypoPG checks locally and explains equivalent-index results', () => {
    const equivalentIndex: QueryIndexAdvice = {
      status: 'NO_IMPROVEMENT',
      reasonCode: 'EQUIVALENT_INDEX_EXISTS',
      message: 'orders_status_customer_idx aynı kolonları kapsıyor.',
      ddlExecuted: false,
    }

    expect(completedHypopgEvaluation(equivalentIndex)).toBe(true)
    expect(completedHypopgEvaluation({ ...equivalentIndex, status: 'VALIDATED', reasonCode: 'VALIDATED' })).toBe(true)
    expect(completedHypopgEvaluation({ ...equivalentIndex, status: 'UNAVAILABLE', reasonCode: 'UNAVAILABLE' })).toBe(false)
    expect(displayedValidatedGroups(2, 3)).toBe(5)
    expect(existingIndexPresentation(demoDatabaseOptimize.items[0], equivalentIndex)).toEqual({
      label: 'Örtüşme bulundu',
      reason: equivalentIndex.message,
    })
  })
})
