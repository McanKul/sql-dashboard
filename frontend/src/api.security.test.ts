import { afterEach, describe, expect, it, vi } from 'vitest'
import { advisorApi } from './api'

afterEach(() => vi.unstubAllGlobals())

describe('browser privilege boundary', () => {
  it('launches query analysis without sending SQL or an index candidate', async () => {
    const fetchMock = vi.fn((_input: string | URL | Request, _init?: RequestInit) => Promise.resolve(new Response(JSON.stringify({
      status: 'UNSAFE', reasonCode: 'SELECT_ONLY', message: 'Yalnız SELECT.', queryId: '-42', validation: null,
      executionTarget: 'SOURCE_DATABASE', sourceExecuted: false, sourceDdlExecuted: false, transactionRolledBack: true,
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })))
    vi.stubGlobal('fetch', fetchMock)

    await advisorApi.explainAnalyzeQuery('1:2:-42', '24h', ['paid'])

    const [url, init] = fetchMock.mock.calls[0]
    expect(String(url)).toContain('/queries/-42/explain-analyze?window=24h')
    expect(init?.method).toBe('POST')
    expect(JSON.parse(String(init?.body))).toEqual({ serverId: 1, databaseId: 2, bindValues: ['paid'] })
    expect(String(init?.body)).not.toContain('normalizedSql')
    expect(String(init?.body)).not.toContain('candidateId')
  })
})
