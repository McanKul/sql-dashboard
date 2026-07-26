import { CheckCircle2, Clock3, ShieldAlert, XCircle } from 'lucide-react'
import type { CapabilityStatus, SourceCapabilityRow } from '../../types'

const statusLabels: Record<CapabilityStatus, string> = {
  AVAILABLE: 'Kullanılabilir',
  WAITING_FOR_DATA: 'Veri bekleniyor',
  DEGRADED: 'Kısıtlı',
  NOT_CONFIGURED: 'Yapılandırılmadı',
  UNREACHABLE: 'Erişilemiyor',
}

function StatusIcon({ status }: { status: CapabilityStatus }) {
  if (status === 'AVAILABLE') return <CheckCircle2 size={15} aria-hidden="true" />
  if (status === 'WAITING_FOR_DATA') return <Clock3 size={15} aria-hidden="true" />
  if (status === 'DEGRADED') return <ShieldAlert size={15} aria-hidden="true" />
  return <XCircle size={15} aria-hidden="true" />
}

export function CapabilityMatrix({ rows }: { rows: SourceCapabilityRow[] }) {
  if (!rows.length) return <div className="capability-empty"><ShieldAlert size={18} /><span>Bu kapsam için capability bilgisi yok.</span></div>
  const columns = rows[0].capabilities
  return (
    <div className="capability-matrix-wrap">
      <table className="capability-matrix">
        <caption className="sr-only">Kaynak ve veritabanı yetenek matrisi</caption>
        <thead><tr><th>Kaynak / veritabanı</th>{columns.map((item) => <th key={item.key}>{item.label}</th>)}</tr></thead>
        <tbody>{rows.map((row) => (
          <tr key={`${row.serverId}:${row.databaseId}`}>
            <th scope="row"><strong>{row.serverAlias}</strong><span>{row.databaseName}</span></th>
            {columns.map((column) => {
              const capability = row.capabilities.find((item) => item.key === column.key) || column
              return <td key={capability.key}>
                <span className={`capability-state ${capability.status.toLowerCase()}`} title={capability.status === 'AVAILABLE' ? undefined : capability.reason || undefined}>
                  <StatusIcon status={capability.status} />
                  <b>{statusLabels[capability.status]}</b>
                  {capability.version && <small>{capability.version}</small>}
                </span>
                {capability.status !== 'AVAILABLE' && <small className="capability-reason">{capability.reason || 'Ayrıntı bildirilmedi.'}</small>}
              </td>
            })}
          </tr>
        ))}</tbody>
      </table>
    </div>
  )
}
