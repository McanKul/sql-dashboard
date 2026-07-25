import type { Severity, TimeWindow, TrendPoint } from './types'

export const numberFormatter = new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 1 })
export const compactNumberFormatter = new Intl.NumberFormat('tr-TR', {
  notation: 'compact',
  maximumFractionDigits: 1,
})

export function formatNumber(value: number, compact = false): string {
  return (compact ? compactNumberFormatter : numberFormatter).format(value)
}

export function formatLargeNumber(value: number): string {
  const absolute = Math.abs(value)
  if (absolute >= 1_000_000_000) return `${formatNumber(value / 1_000_000_000)} milyar`
  if (absolute >= 1_000_000) return `${formatNumber(value / 1_000_000)} milyon`
  if (absolute >= 1_000) return `${formatNumber(value / 1_000)} bin`
  return formatNumber(value)
}

export function formatScoreContribution(value: number): string {
  return new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 3 }).format(value)
}

export function formatVolumeFactor(value: number): string {
  return `%${new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 4 }).format(value * 100)}`
}

export function scoreRelativeLabel(percentile: number): string {
  if (percentile >= 90) return 'Listedeki en yüksek değerlerden'
  if (percentile >= 70) return 'Listenin üst sıralarında'
  if (percentile >= 40) return 'Listenin orta sıralarında'
  return 'Listenin alt sıralarında'
}

export function scoreVolumeLabel(factor: number): string {
  if (factor <= 0) return 'Gerçek yük yok'
  if (factor < 0.01) return 'Gerçek yük çok düşük'
  if (factor < 0.25) return 'Gerçek yük düşük'
  if (factor < 0.75) return 'Gerçek yük orta'
  if (factor < 1) return 'Gerçek yük yüksek'
  return 'Gerçek yük tam puan eşiğinde'
}

export function scoreContributionLabel(contribution: number, maximum: number): string {
  if (contribution <= 0) return 'Toplam puanı etkilemiyor'
  const ratio = maximum > 0 ? contribution / maximum : 0
  if (ratio < 0.1) return 'Toplam puana etkisi çok düşük'
  if (ratio < 0.5) return 'Toplam puanı bir miktar yükseltiyor'
  return 'Toplam puanı güçlü biçimde yükseltiyor'
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  return `${formatNumber(bytes / (1024 ** index))} ${units[index]}`
}

export function formatCacheHit(hit: number, read: number): string {
  const total = hit + read
  if (!Number.isFinite(total) || total <= 0) return '—'
  const percent = (hit / total) * 100
  if (percent < 100 && percent > 99.99) return '>%99,99'
  return `%${new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 2 }).format(percent)}`
}

export const windowLabels: Record<TimeWindow, string> = {
  '1h': 'Son 1 saat',
  '24h': 'Son 24 saat',
  '7d': 'Son 7 gün',
  '30d': 'Son 30 gün',
}

export function formatDuration(milliseconds: number): string {
  if (milliseconds < 1) return `${Math.round(milliseconds * 1000)} µs`
  if (milliseconds < 1000) return `${formatNumber(milliseconds)} ms`
  const seconds = milliseconds / 1000
  if (seconds < 60) return `${formatNumber(seconds)} sn`
  const minutes = seconds / 60
  if (minutes < 60) return `${formatNumber(minutes)} dk`
  const hours = minutes / 60
  if (hours < 24) return `${formatNumber(hours)} saat`
  return `${formatNumber(hours / 24)} gün`
}

export function comparisonAvailable(previousCalls: number, currentCalls = Number.POSITIVE_INFINITY): boolean {
  return Number.isFinite(previousCalls) && previousCalls >= 20
    && currentCalls >= 20
}

export function formatDateTime(value: string): string {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '—'
  return new Intl.DateTimeFormat('tr-TR', {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date)
}

export function relativeTime(value: string, now = Date.now()): string {
  const timestamp = new Date(value).getTime()
  if (Number.isNaN(timestamp)) return '—'
  const seconds = Math.round((timestamp - now) / 1000)
  const formatter = new Intl.RelativeTimeFormat('tr', { numeric: 'auto' })
  if (Math.abs(seconds) < 60) return formatter.format(seconds, 'second')
  const minutes = Math.round(seconds / 60)
  if (Math.abs(minutes) < 60) return formatter.format(minutes, 'minute')
  const hours = Math.round(minutes / 60)
  if (Math.abs(hours) < 24) return formatter.format(hours, 'hour')
  return formatter.format(Math.round(hours / 24), 'day')
}

export const severityLabels: Record<Severity, string> = {
  critical: 'Kritik',
  warning: 'Dikkat',
  healthy: 'Sağlıklı',
}

export function chartPoints(
  points: TrendPoint[],
  width = 320,
  height = 112,
  padding = 8,
): string {
  if (!points.length) return ''
  const values = points.map((point) => point.value)
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const innerWidth = width - padding * 2
  const innerHeight = height - padding * 2

  return points.map((point, index) => {
    const x = padding + (points.length === 1 ? innerWidth / 2 : (index / (points.length - 1)) * innerWidth)
    const y = padding + ((max - point.value) / range) * innerHeight
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}
