import type { Severity, TrendPoint } from './types'

export const numberFormatter = new Intl.NumberFormat('tr-TR', { maximumFractionDigits: 1 })
export const compactNumberFormatter = new Intl.NumberFormat('tr-TR', {
  notation: 'compact',
  maximumFractionDigits: 1,
})

export function formatNumber(value: number, compact = false): string {
  return (compact ? compactNumberFormatter : numberFormatter).format(value)
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

export function comparisonAvailable(previousCalls: number): boolean {
  return Number.isFinite(previousCalls) && previousCalls >= 5
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
