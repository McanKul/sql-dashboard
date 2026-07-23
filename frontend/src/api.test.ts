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
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(jsonResponse({
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
      previousCalls: 0,
      previousMeanExecTimeMs: 0,
      regressionPercent: 0,
      impactScore: 1,
      priority: 'LOW',
      status: 'NEW',
      findings: [],
      p95ExecTimeMs: null,
      durationDistribution: { available: false, reason: 'Dağılım verisi yok.' },
      scoreBreakdown: { physicalRead: { weight: 0.2, contribution: 0.03, percentileScore: 100, volumeFactor: 0.006, absoluteValue: 6, fullScoreAt: 1000, unit: 'blocks' } },
      trend: [{ timestamp: '2026-07-23T08:00:00Z', totalExecTimeMs: 20, calls: 10 }],
      comparison: { currentMeanMs: 2, previousMeanMs: 0, regressionPercent: 0, currentCalls: 10, previousCalls: 0 },
    }))))

    const { data } = await advisorApi.getQuery('1:2:-42', '24h')

    expect(data.p95DurationMs).toBeUndefined()
    expect(data.durationDistribution).toEqual({ available: false, reason: 'Dağılım verisi yok.' })
    expect(data.rowsPerCall).toBe(3)
    expect(data.scoreBreakdown[0]).toMatchObject({ contribution: 0.03, volumeFactor: 0.006, fullScoreAt: 1000 })
  })
})
