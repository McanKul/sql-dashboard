import { describe, expect, it } from 'vitest'
import { advisorApi } from './api'

describe('browser privilege boundary', () => {
  it('does not expose an admin runtime launcher in the browser client', () => {
    expect(advisorApi).not.toHaveProperty('validateIndexRuntime')
  })
})
