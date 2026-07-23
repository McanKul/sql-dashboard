import { describe, expect, it } from 'vitest'
import { chartPoints, comparisonAvailable, formatCacheHit, formatDuration, formatLargeNumber, formatScoreContribution, formatVolumeFactor } from './utils'

describe('formatDuration', () => {
  it('uses useful units for query timings', () => {
    expect(formatDuration(.25)).toContain('µs')
    expect(formatDuration(125)).toContain('ms')
    expect(formatDuration(1250)).toContain('sn')
    expect(formatDuration(90_000)).toContain('dk')
    expect(formatDuration(7_200_000)).toContain('saat')
    expect(formatDuration(172_800_000)).toContain('gün')
  })
})

describe('comparisonAvailable', () => {
  it('requires at least five calls in the previous window', () => {
    expect(comparisonAvailable(4)).toBe(false)
    expect(comparisonAvailable(5)).toBe(true)
    expect(comparisonAvailable(Number.NaN)).toBe(false)
  })
})

describe('telemetry formatting', () => {
  it('does not round a near-perfect cache ratio to exact 100 percent', () => {
    expect(formatCacheHit(1_448_474_149, 6)).toBe('>%99,99')
    expect(formatCacheHit(0, 0)).toBe('—')
  })

  it('uses readable Turkish scale names instead of compact abbreviations', () => {
    expect(formatLargeNumber(1_400_000_000)).toContain('milyar')
    expect(formatLargeNumber(2_400_000)).toContain('milyon')
  })

  it('keeps small non-zero score factors visible', () => {
    expect(formatScoreContribution(0.03)).toBe('0,03')
    expect(formatVolumeFactor(0.0003)).toBe('%0,03')
  })
})

describe('chartPoints', () => {
  it('maps a trend into a bounded polyline', () => {
    const result = chartPoints([{ label: 'a', value: 10 }, { label: 'b', value: 20 }], 100, 50, 5)
    expect(result).toBe('5.0,45.0 95.0,5.0')
  })

  it('returns an empty string for empty series', () => {
    expect(chartPoints([])).toBe('')
  })
})
