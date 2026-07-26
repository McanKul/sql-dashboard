import { describe, expect, it } from 'vitest'
import {
  buildAppHash,
  parseAppHash,
  queryAfterScopeChange,
  queryBelongsToScope,
  resolveScope,
  scopedQuery,
} from './scope'

const servers = [{ id: 1, alias: 'erp-prod' }, { id: 2, alias: 'reporting' }]
const databases = [
  { serverId: 1, databaseId: 10, name: 'erp' },
  { serverId: 1, databaseId: 11, name: 'archive' },
  { serverId: 2, databaseId: 10, name: 'reporting' },
]

describe('global analysis scope', () => {
  it('round-trips page, exact server/database, window and query deep-link', () => {
    const hash = buildAppHash({ page: 'queries', scope: { serverId: 1, databaseId: 10 }, window: '7d', queryId: '1:10:-42' })
    expect(parseAppHash(hash)).toEqual({ page: 'queries', scope: { serverId: 1, databaseId: 10 }, window: '7d', queryId: '1:10:-42' })
  })

  it('never accepts a database without its server', () => {
    expect(parseAppHash('#/health?databaseId=10&window=1h').scope).toEqual({ serverId: undefined, databaseId: undefined })
  })

  it('defaults an invalid or empty request to the first exact database', () => {
    expect(resolveScope({}, servers, databases)).toEqual({ serverId: 1, databaseId: 10 })
    expect(resolveScope({ serverId: 2, databaseId: 11 }, servers, databases)).toEqual({ serverId: 2, databaseId: 10 })
  })

  it('sends the same scope shape to scoped APIs', () => {
    expect(scopedQuery('30d', { serverId: 1, databaseId: 10 }).toString()).toBe('window=30d&serverId=1&databaseId=10')
  })

  it('closes a selected query when the exact database scope changes', () => {
    const queryId = '1:10:-42'
    expect(queryBelongsToScope(queryId, { serverId: 1, databaseId: 10 })).toBe(true)
    expect(queryBelongsToScope(queryId, { serverId: 1, databaseId: 11 })).toBe(false)
    expect(queryAfterScopeChange({ serverId: 1, databaseId: 10 }, { serverId: 1, databaseId: 11 }, queryId)).toBeNull()
    expect(queryAfterScopeChange({ serverId: 1, databaseId: 10 }, { serverId: 1, databaseId: 10 }, queryId)).toBe(queryId)
  })
})
