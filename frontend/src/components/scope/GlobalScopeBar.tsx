import { ChevronDown, Clock3, Database, Network } from 'lucide-react'
import type { AnalysisScope, DatabaseOption, ServerOption, TimeWindow } from '../../types'

const windows: TimeWindow[] = ['1h', '24h', '7d', '30d']

export function GlobalScopeBar({
  servers,
  databases,
  scope,
  window,
  availableCapabilities,
  totalCapabilities,
  capabilityStatus,
  onCapabilitiesRetry,
  onScopeChange,
  onWindowChange,
}: {
  servers: ServerOption[]
  databases: DatabaseOption[]
  scope: AnalysisScope
  window: TimeWindow
  availableCapabilities: number
  totalCapabilities: number
  capabilityStatus: 'idle' | 'loading' | 'success' | 'error'
  onCapabilitiesRetry: () => void
  onScopeChange: (scope: AnalysisScope) => void
  onWindowChange: (window: TimeWindow) => void
}) {
  const scopedDatabases = databases.filter((item) => item.serverId === scope.serverId)

  const selectServer = (serverId: number) => {
    const firstDatabase = databases.find((item) => item.serverId === serverId)
    onScopeChange({ serverId, databaseId: firstDatabase?.databaseId })
  }

  return (
    <div className="global-scope-bar" aria-label="Aktif analiz kapsamı">
      <label className="scope-select">
        <Network size={14} aria-hidden="true" />
        <span className="sr-only">Aktif sunucu</span>
        <select value={scope.serverId ?? ''} onChange={(event) => selectServer(Number(event.target.value))} disabled={!servers.length}>
          {!servers.length && <option value="">Sunucu yükleniyor</option>}
          {servers.map((server) => <option key={server.id} value={server.id}>{server.alias || server.hostname || `server-${server.id}`}</option>)}
        </select>
        <ChevronDown size={12} aria-hidden="true" />
      </label>
      <label className="scope-select">
        <Database size={14} aria-hidden="true" />
        <span className="sr-only">Aktif veritabanı</span>
        <select
          value={scope.databaseId ?? ''}
          onChange={(event) => onScopeChange({ serverId: scope.serverId, databaseId: Number(event.target.value) })}
          disabled={!scope.serverId || !scopedDatabases.length}
        >
          {!scopedDatabases.length && <option value="">Veritabanı yükleniyor</option>}
          {scopedDatabases.map((database) => <option key={`${database.serverId}:${database.databaseId}`} value={database.databaseId}>{database.name}</option>)}
        </select>
        <ChevronDown size={12} aria-hidden="true" />
      </label>
      <div className="scope-window" aria-label="Analiz zaman aralığı">
        <Clock3 size={13} aria-hidden="true" />
        {windows.map((item) => <button type="button" key={item} className={window === item ? 'active' : ''} onClick={() => onWindowChange(item)} aria-pressed={window === item}>{item}</button>)}
      </div>
      <button
        type="button"
        className={`scope-capability-count ${capabilityStatus === 'error' ? 'error' : ''}`}
        title={capabilityStatus === 'error' ? 'Capability isteği başarısız; yeniden dene' : `${totalCapabilities} yetenekten ${availableCapabilities} tanesi kullanılabilir · yenile`}
        onClick={onCapabilitiesRetry}
        disabled={capabilityStatus === 'loading'}
      >
        <i aria-hidden="true" /> {capabilityStatus === 'error' ? 'Yetenekleri yenile' : capabilityStatus === 'loading' ? 'Yükleniyor' : `${availableCapabilities}/${totalCapabilities || '—'} aktif`}
      </button>
    </div>
  )
}
