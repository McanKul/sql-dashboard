import { afterEach, describe, expect, it, vi } from 'vitest'
import { advisorApi } from './api'

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

afterEach(() => vi.unstubAllGlobals())

describe('advisor API contracts', () => {
  it('does not turn unavailable or unreliable query history into zero regression', async () => {
    const base = {
      serverId: 1, databaseId: 2, databaseName: 'app', sql: 'select 1', sqlVisible: true,
      calls: 25, totalExecTimeMs: 50, meanExecTimeMs: 2, dbLoadPercent: 1,
      sharedBlocksHit: 10, sharedBlocksRead: 0, tempBlocksWritten: 0, walBytes: 0,
      impactScore: 5, priority: 'LOW', status: 'NEW', findings: [], scoreBreakdown: {},
      observedFrom: '2026-07-24T08:00:00Z', observedTo: '2026-07-25T08:00:00Z',
      coveragePercent: 100, warmingUp: false,
    }
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(jsonResponse({
      items: [
        { ...base, queryId: '1', resetDetected: false, comparisonReliable: true, previousPeriodAvailable: true, previousCalls: 25, previousMeanExecTimeMs: 1.5, regressionPercent: 33.33 },
        { ...base, queryId: '2', resetDetected: true, comparisonReliable: false, previousPeriodAvailable: false, previousCalls: null, previousMeanExecTimeMs: null, regressionPercent: null },
      ],
      total: 2,
    }))))

    const { data } = await advisorApi.getQueries('24h', { page: 1, pageSize: 50 })

    expect(data.items[0]).toMatchObject({ lastSeenAt: '2026-07-25T08:00:00Z', changePercent: 33.33, hasComparison: true, comparisonReliable: true })
    expect(data.items[1]).toMatchObject({ lastSeenAt: '2026-07-25T08:00:00Z', changePercent: null, hasComparison: false, resetDetected: true, previousPeriodAvailable: false })
  })

  it('keeps repository index, IO capability, and detailed telemetry fields', async () => {
    vi.stubGlobal('fetch', vi.fn((input: string | URL | Request) => {
      const url = String(input)
      if (url.includes('/operations')) return Promise.resolve(jsonResponse({
        architecture: { source: { count: 1 }, dataFlow: ['source', 'repository'], apiSourceConnection: false },
        services: [],
        collector: { alias: 'primary', hostname: 'db', port: 5432, retention: '90 days', errors: [] },
        collectors: [{ serverId: 1, alias: 'primary', hostname: 'db', port: 5432, retention: '90 days', errors: [] }],
        repository: { sizeBytes: 1024, retentionDays: 90 },
      }))
      if (url.includes('/indexes')) return Promise.resolve(jsonResponse({
        summary: { indexesObserved: 1, candidateSignals: 0, totalSizeBytes: 2048, noScanSizeBytes: 0 },
        items: [{ serverId: 1, databaseId: 2, databaseName: 'app', relationId: 10, indexId: 11, tableName: 'orders', indexName: 'orders_pkey', sizeBytes: 2048, scans: 3, tuplesRead: 8, tuplesFetched: 5, signalLevel: 'UNKNOWN', signal: 'INSUFFICIENT_DATA', recommendation: 'Yeterli gözlem yok.' }],
      }))
      if (url.includes('/io')) return Promise.resolve(jsonResponse({
        summary: { reads: 1, writes: 2, readBytes: 8192, writeBytes: 16384, extendBytes: 4096, cacheHits: 10, cacheHitPercent: 90, tempBytes: 0, walBytes: 32, checkpoints: 1, checkpointWriteTimeMs: 4, backendWrites: 2 },
        capabilities: [{ key: 'checkpointAndBgwriter', available: true, resetEpochAware: false, source: 'PoWA checkpoint', limitation: 'Reset zamanı yok.' }],
        databases: [{ serverId: 1, databaseId: 2, databaseName: 'app', blocksRead: 1, blocksHit: 10, tuplesInserted: 4 }],
        contexts: [{ serverId: 1, reads: 1, readBytes: 8192, writebacks: 2, extends: 3, fsyncs: 4 }],
        servers: [{ serverId: 1, walBytes: 32, walBuffersFull: 1, checkpointBuffersWritten: 2 }],
      }))
      throw new Error(`Beklenmeyen URL: ${url}`)
    }))

    const { data } = await advisorApi.getOperations('24h')

    expect(data.collectors[0].port).toBe(5432)
    expect(data.indexes.summary?.noScanSizeBytes).toBe(0)
    expect(data.indexes.items[0]).toMatchObject({ relationId: 10, indexId: 11, tuplesRead: 8, tuplesFetched: 5, signal: 'INSUFFICIENT_DATA' })
    expect(data.io.capabilities[0]).toMatchObject({ resetEpochAware: false, limitation: 'Reset zamanı yok.' })
    expect(data.io.contexts[0]).toMatchObject({ writebacks: 2, extends: 3, fsyncs: 4 })
    expect(data.io.servers[0]).toMatchObject({ walBuffersFull: 1, checkpointBuffersWritten: 2 })
  })

  it('preserves honest p95 unavailability and low non-zero score contributions', async () => {
    vi.stubGlobal('fetch', vi.fn((input: string | URL | Request) => {
      const url = String(input)
      if (url.includes('/predicates')) return Promise.resolve(jsonResponse({
        window: '24h',
        queryId: '-42',
        capability: { available: true, version: '2.1.4', dataAvailable: true, coverage: 'WHERE_FILTER_ONLY', joinsAvailable: false, ddlGenerated: false, reason: 'Yalnız WHERE/filter geçmişi.' },
        items: [{ qualId: '99', relationId: 10, schemaName: 'public', tableName: 'orders', columns: ['status'], operatorOids: [98], evalType: 'FILTER', occurrences: 12, rowsProcessed: 1000, rowsFiltered: 750, filterRatio: .75, observedFrom: '2026-07-23T07:00:00Z', observedTo: '2026-07-23T08:00:00Z', sampleCount: 4, signal: 'REVIEW', recommendation: 'Planla doğrulayın.' }],
      }))
      return Promise.resolve(jsonResponse({
      serverId: 1,
      databaseId: 2,
      databaseName: 'app',
      queryId: '-42',
      sql: 'select * from orders',
      sqlVisible: true,
      calls: 10,
      rows: 30,
      rowsPerCall: 3,
      totalExecTimeMs: 20,
      meanExecTimeMs: 2,
      dbLoadPercent: 1,
      sharedBlocksHit: 100,
      sharedBlocksRead: 6,
      tempBlocksWritten: 0,
      walBytes: 0,
      cpu: {
        capability: { available: true, version: '2.3.2', dataAvailable: true, source: 'PoWA pg_stat_kcache', coverage: 'EXECUTION_ONLY', reason: 'CPU ölçüldü.' },
        userTimeMs: 8,
        systemTimeMs: 2,
        totalTimeMs: 10,
        percentOfExecTime: 50,
        filesystemReadsBytes: 4096,
        filesystemWritesBytes: 0,
        scoreIncluded: false,
      },
      observedFrom: '2026-07-23T07:00:00Z',
      observedTo: '2026-07-23T08:00:00Z',
      coveragePercent: 42.5,
      resetDetected: true,
      comparisonReliable: false,
      warmingUp: false,
      previousPeriodAvailable: false,
      previousCalls: null,
      previousMeanExecTimeMs: null,
      regressionPercent: null,
      impactScore: 1,
      priority: 'LOW',
      status: 'NEW',
      findings: [],
      p95ExecTimeMs: null,
      durationDistribution: { available: false, reason: 'Dağılım verisi yok.' },
      scoreBreakdown: { physicalRead: { weight: 0.2, contribution: 0.03, percentileScore: 100, volumeFactor: 0.006, absoluteValue: 6, fullScoreAt: 1000, unit: 'blocks' } },
      trend: [{ timestamp: '2026-07-23T08:00:00Z', totalExecTimeMs: 20, calls: 10 }],
      comparison: { currentMeanMs: 2, previousMeanMs: null, regressionPercent: null, currentCalls: 10, previousCalls: null },
      }))
    }))

    const { data } = await advisorApi.getQuery('1:2:-42', '24h')

    expect(data.p95DurationMs).toBeUndefined()
    expect(data.durationDistribution).toEqual({ available: false, reason: 'Dağılım verisi yok.' })
    expect(data.rowsPerCall).toBe(3)
    expect(data.cpu).toMatchObject({ totalTimeMs: 10, percentOfExecTime: 50, scoreIncluded: false })
    expect(data.cpu.capability).toMatchObject({ available: true, version: '2.3.2', dataAvailable: true })
    expect(data).toMatchObject({
      observedFrom: '2026-07-23T07:00:00Z',
      observedTo: '2026-07-23T08:00:00Z',
      lastSeenAt: '2026-07-23T08:00:00Z',
      coveragePercent: 42.5,
      resetDetected: true,
      comparisonReliable: false,
      warmingUp: false,
      previousPeriodAvailable: false,
      changePercent: null,
      hasComparison: false,
      comparison: [],
    })
    expect(data.scoreBreakdown[0]).toMatchObject({ contribution: 0.03, volumeFactor: 0.006, fullScoreAt: 1000 })
    expect(data.predicates.capability).toMatchObject({ available: true, coverage: 'WHERE_FILTER_ONLY', joinsAvailable: false, ddlGenerated: false })
    expect(data.predicates.items[0]).toMatchObject({ tableName: 'orders', columns: ['status'], occurrences: 12, rowsProcessed: 1000, rowsFiltered: 750, signal: 'REVIEW' })
  })

  it('requests on-demand HypoPG validation with identifiers only', async () => {
    const fetchMock = vi.fn((input: string | URL | Request, init?: RequestInit) => {
      expect(String(input)).toContain('/queries/-42/index-evaluations?window=24h')
      expect(init?.method).toBe('POST')
      expect(JSON.parse(String(init?.body))).toEqual({ serverId: 1, databaseId: 2, qualId: '99', relationId: 10 })
      return Promise.resolve(jsonResponse({
        status: 'VALIDATED',
        reasonCode: 'COST_REDUCTION_CONFIRMED',
        message: 'Sanal index planda kullanildi.',
        candidate: { method: 'btree', columns: ['status'], createIndexSql: 'CREATE INDEX CONCURRENTLY idx ON public.orders (status);', copyable: true },
        validation: { mode: 'GENERIC_PLAN', hypopgVersion: '1.4.3', baselineTotalCost: 460, hypotheticalTotalCost: 120, costReductionPercent: 73.91, hypotheticalIndexUsed: true, estimatedIndexSizeBytes: 1024, tableSizeBytes: 4096, evaluatedAt: '2026-07-24T14:00:00Z' },
        confidence: { level: 'HIGH', reasons: ['Sanal index kullanildi.'] },
        ddlExecuted: false,
      }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const { data } = await advisorApi.evaluateIndex('1:2:-42', '24h', {
      qualId: '99', relationId: 10, schemaName: 'public', tableName: 'orders', columns: ['status'], operatorOids: [98], evalType: 'FILTER', occurrences: 12, rowsProcessed: 1000, rowsFiltered: 750, filterRatio: .75, observedFrom: '2026-07-24T13:00:00Z', observedTo: '2026-07-24T14:00:00Z', sampleCount: 4, signal: 'REVIEW', recommendation: 'Planla dogrulayin.',
    })

    expect(data).toMatchObject({ status: 'VALIDATED', ddlExecuted: false, candidate: { columns: ['status'], copyable: true } })
  })

  it('requests source-database EXPLAIN ANALYZE with identifiers and scalar binds only', async () => {
    const fetchMock = vi.fn((input: string | URL | Request, init?: RequestInit) => {
      expect(String(input)).toContain('/queries/-42/explain-analyze?window=7d')
      expect(init?.method).toBe('POST')
      expect(JSON.parse(String(init?.body))).toEqual({ serverId: 1, databaseId: 2, bindValues: ['paid', 100, true, null] })
      return Promise.resolve(jsonResponse({
        status: 'RUNTIME_VALIDATED', reasonCode: 'READ_ONLY_QUERY_ANALYZED', message: 'Clone üzerinde ölçüldü.', queryId: '-42',
        validation: {
          mode: 'EXPLAIN_ANALYZE', statementClass: 'READ_ONLY_SELECT', planPreflight: 'READ_ONLY', transactionReadOnly: true,
          safetyPolicyRevision: 1, postgresVersion: '18.4', executionRole: 'advisor_explain', databaseId: 2, executionTimeMs: 4.2, planningTimeMs: .3,
          sharedHitBlocks: 12, sharedReadBlocks: 1, tempReadBlocks: 0, tempWrittenBlocks: 0,
          walRecords: 0, walBytes: 0, plan: { Plan: { 'Node Type': 'Index Scan' } }, evaluatedAt: '2026-07-26T14:00:00Z',
        },
        executionTarget: 'SOURCE_DATABASE', sourceExecuted: true, sourceDdlExecuted: false, transactionRolledBack: true,
      }))
    })
    vi.stubGlobal('fetch', fetchMock)

    const { data } = await advisorApi.explainAnalyzeQuery('1:2:-42', '7d', ['paid', 100, true, null])

    expect(data).toMatchObject({
      status: 'RUNTIME_VALIDATED', queryId: '-42', executionTarget: 'SOURCE_DATABASE',
      sourceExecuted: true, sourceDdlExecuted: false, transactionRolledBack: true,
      validation: { executionTimeMs: 4.2, statementClass: 'READ_ONLY_SELECT', transactionReadOnly: true },
    })
  })

  it('sends an empty bind array for a parameterless query', async () => {
    const fetchMock = vi.fn((_input: string | URL | Request, init?: RequestInit) => {
      expect(JSON.parse(String(init?.body))).toEqual({ serverId: 1, databaseId: 2, bindValues: [] })
      return Promise.resolve(jsonResponse({
        status: 'UNAVAILABLE', reasonCode: 'CLONE_OFFLINE', message: 'Clone kapalı.', queryId: '-42', validation: null,
        executionTarget: 'SOURCE_DATABASE', sourceExecuted: null, sourceDdlExecuted: false, transactionRolledBack: null,
      }))
    })
    vi.stubGlobal('fetch', fetchMock)

    await advisorApi.explainAnalyzeQuery('1:2:-42', '1h', [])
    expect(fetchMock).toHaveBeenCalledOnce()
  })
})
