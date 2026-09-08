import { describe, expect, it } from 'vitest'
import type { Context } from '@deepseek-ai/cordis'
import { apply, assertPositiveInteger, Config, resolveConfig } from '../src/index.ts'

function stubContext(): Context {
  return {
    webServer: { port: 3080, registerUpgrade: () => () => {}, register: () => () => {} },
    tools: { register: () => () => {} },
    get: () => undefined,
    logger: { info: () => {}, warn: () => {}, error: () => {} },
    effect: (fn: () => unknown) => fn() as () => void,
  } as unknown as Context
}

describe('SketchUp bridge config', () => {
  it('accepts only positive integer budgets', () => {
    expect(() => assertPositiveInteger('x', 1)).not.toThrow()
    expect(() => assertPositiveInteger('x', 0)).toThrow(/positive integer/)
    expect(() => assertPositiveInteger('x', 1.5)).toThrow(/positive integer/)
  })

  it('applies defaults while preserving explicit values', () => {
    expect(resolveConfig({})).toEqual({
      toolTimeoutMs: 90_000,
      maxHistoryEvents: 200,
      maxEventPayloadBytes: 65_536,
      maxResultChars: 120_000,
      allowPluginWrite: false,
      allowPluginLoad: false,
    })
    expect(resolveConfig({ toolTimeoutMs: 1, maxHistoryEvents: 2, maxEventPayloadBytes: 3, maxResultChars: 4, allowPluginWrite: true, allowPluginLoad: true }))
      .toEqual({ toolTimeoutMs: 1, maxHistoryEvents: 2, maxEventPayloadBytes: 3, maxResultChars: 4, allowPluginWrite: true, allowPluginLoad: true })
    expect(new Config().maxHistoryEvents).toBe(200)
  })

  it('rejects invalid budgets at the plugin boundary', async () => {
    await expect(apply(stubContext(), { maxHistoryEvents: 0 })).rejects.toThrow(/maxHistoryEvents/)
    await expect(apply(stubContext(), { maxResultChars: 1.5 })).rejects.toThrow(/maxResultChars/)
  })
})
