import type { AnalysisScope, DatabaseOption, PageId, ServerOption, TimeWindow } from './types'

export interface AppLocationState {
  page: PageId
  scope: AnalysisScope
  window: TimeWindow
  queryId: string | null
}

const pages = new Set<PageId>(['overview', 'queries', 'optimize', 'health', 'operations'])
const windows = new Set<TimeWindow>(['1h', '24h', '7d', '30d'])

const positiveInteger = (value: string | null): number | undefined => {
  if (!value) return undefined
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined
}

export function parseAppHash(hash: string): AppLocationState {
  const raw = hash.replace(/^#\/?/, '')
  const [pagePart, queryPart = ''] = raw.split('?', 2)
  const params = new URLSearchParams(queryPart)
  const page = pages.has(pagePart as PageId) ? pagePart as PageId : 'overview'
  const serverId = positiveInteger(params.get('serverId'))
  const databaseId = serverId === undefined ? undefined : positiveInteger(params.get('databaseId'))
  const requestedWindow = params.get('window') as TimeWindow | null
  return {
    page,
    scope: { serverId, databaseId },
    window: requestedWindow && windows.has(requestedWindow) ? requestedWindow : '24h',
    queryId: params.get('query') || null,
  }
}

export function buildAppHash({ page, scope, window, queryId }: AppLocationState): string {
  const params = new URLSearchParams({ window })
  if (scope.serverId !== undefined) params.set('serverId', String(scope.serverId))
  if (scope.serverId !== undefined && scope.databaseId !== undefined) params.set('databaseId', String(scope.databaseId))
  if (queryId) params.set('query', queryId)
  return `#/${page}?${params.toString()}`
}

export function resolveScope(
  requested: AnalysisScope,
  servers: ServerOption[],
  databases: DatabaseOption[],
): AnalysisScope {
  if (!servers.length || !databases.length) return requested
  const requestedServer = servers.find((item) => item.id === requested.serverId)
  const server = requestedServer && databases.some((item) => item.serverId === requestedServer.id)
    ? requestedServer
    : servers.find((item) => databases.some((database) => database.serverId === item.id)) || servers[0]
  const matchingDatabases = databases.filter((item) => item.serverId === server.id)
  const database = matchingDatabases.find((item) => item.databaseId === requested.databaseId) || matchingDatabases[0]
  return { serverId: server.id, databaseId: database?.databaseId }
}

export function sameScope(left: AnalysisScope, right: AnalysisScope): boolean {
  return left.serverId === right.serverId && left.databaseId === right.databaseId
}

export function queryBelongsToScope(queryId: string | null, scope: AnalysisScope): boolean {
  if (!queryId || scope.serverId === undefined || scope.databaseId === undefined) return false
  const [serverId, databaseId, ...queryParts] = queryId.split(':')
  return queryParts.length > 0
    && Number(serverId) === scope.serverId
    && Number(databaseId) === scope.databaseId
}

export function queryAfterScopeChange(
  currentScope: AnalysisScope,
  nextScope: AnalysisScope,
  selectedQuery: string | null,
): string | null {
  return sameScope(currentScope, nextScope) ? selectedQuery : null
}

export function scopedQuery(window: TimeWindow, scope: AnalysisScope): URLSearchParams {
  const params = new URLSearchParams({ window })
  if (scope.serverId !== undefined) params.set('serverId', String(scope.serverId))
  if (scope.serverId !== undefined && scope.databaseId !== undefined) params.set('databaseId', String(scope.databaseId))
  return params
}
