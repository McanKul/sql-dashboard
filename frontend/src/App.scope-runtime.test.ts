import { createElement } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import { FleetCapabilityMatrix, ScopeBootstrapPanel, SystemHealthPage } from './App'
import { GlobalScopeBar } from './components/scope/GlobalScopeBar'
import { demoCapabilities } from './demoData'
import appSource from './App.tsx?raw'
import stylesheet from './styles.css?raw'

describe('scope-aware runtime UX', () => {
  it('makes metadata bootstrap failure and retry visible before scoped data can load', () => {
    const markup = renderToStaticMarkup(createElement(ScopeBootstrapPanel, {
      state: { status: 'error', error: 'Repository erişilemiyor.' },
      onRetry: vi.fn(),
    }))

    expect(markup).toContain('Kaynak kapsamı alınamadı')
    expect(markup).toContain('Repository erişilemiyor.')
    expect(markup).toContain('Kesin bir sunucu/veritabanı seçilmeden analiz sorguları başlatılmadı.')
    expect(markup).toContain('Yeniden dene')
  })

  it('renders the independently loaded fleet capability matrix and its retry state', () => {
    const successMarkup = renderToStaticMarkup(createElement(FleetCapabilityMatrix, {
      state: { status: 'success', data: demoCapabilities },
      onRetry: vi.fn(),
    }))
    const errorMarkup = renderToStaticMarkup(createElement(FleetCapabilityMatrix, {
      state: { status: 'error', error: 'Fleet capability çağrısı başarısız.' },
      onRetry: vi.fn(),
    }))

    expect(successMarkup).toContain('Kaynak ve veritabanı yetenek matrisi')
    expect(errorMarkup).toContain('Fleet capability çağrısı başarısız.')
    expect(errorMarkup).toContain('Yeniden dene')
  })

  it('states that System Health is a current snapshot independent of the time filter', () => {
    const markup = renderToStaticMarkup(createElement(SystemHealthPage, {
      state: {
        status: 'success',
        data: {
          collectedAt: '2026-07-26T12:00:00Z', postgresVersion: 'PostgreSQL 18', overall: 'healthy',
          metrics: [], databases: [], capabilities: [],
        },
      },
      onRetry: vi.fn(),
    }))

    expect(markup).toContain('güncel snapshot')
    expect(markup).toContain('Zaman filtresinden bağımsız anlık ölçüm')
  })

  it('keeps the 30d option available on mobile', () => {
    const markup = renderToStaticMarkup(createElement(GlobalScopeBar, {
      servers: [{ id: 1, alias: 'erp-prod' }],
      databases: [{ serverId: 1, databaseId: 10, name: 'erp' }],
      scope: { serverId: 1, databaseId: 10 }, window: '30d',
      availableCapabilities: 7, totalCapabilities: 8,
      capabilityStatus: 'success', onCapabilitiesRetry: vi.fn(),
      onScopeChange: vi.fn(), onWindowChange: vi.fn(),
    }))
    expect(markup).toContain('aria-pressed="true">30d</button>')
    expect(stylesheet).not.toMatch(/\.scope-window button:nth-of-type\(4\)\s*\{[^}]*display:\s*none/)
  })

  it('keeps expensive scoped page requests lazy and fleet capabilities unscoped', () => {
    expect(appSource).toContain("if (page !== 'overview' || !exactScopeReady) return")
    expect(appSource).toContain("if (page !== 'queries' || !exactScopeReady || !sameScope(queryParams, scope)) return")
    expect(appSource).toContain("if (page !== 'health' || !exactScopeReady) return")
    expect(appSource).toContain("if (page !== 'operations' || !exactScopeReady) return")
    expect(appSource).toContain('advisorApi.getCapabilities(timeWindow, {}, controller.signal)')
    expect(appSource).toContain('window.setInterval(loadCapabilities, 60_000)')
    expect(appSource).toContain('capabilityController.current?.abort()')
    expect(appSource).not.toContain('[loadOverview(), loadHealth(), loadOperations(), loadCapabilities()]')
  })

  it('offers a compact manual recovery action when selected capabilities fail', () => {
    const markup = renderToStaticMarkup(createElement(GlobalScopeBar, {
      servers: [{ id: 1, alias: 'erp-prod' }],
      databases: [{ serverId: 1, databaseId: 10, name: 'erp' }],
      scope: { serverId: 1, databaseId: 10 }, window: '24h',
      availableCapabilities: 0, totalCapabilities: 0,
      capabilityStatus: 'error', onCapabilitiesRetry: vi.fn(),
      onScopeChange: vi.fn(), onWindowChange: vi.fn(),
    }))
    expect(markup).toContain('Yetenekleri yenile')
    expect(markup).toContain('Capability isteği başarısız; yeniden dene')
  })
})
