import { describe, expect, it } from 'vitest'
import {
  SKETCHUP_BRIDGE_ORIGIN,
  isClientFrame,
  isServerFrame,
  parseBridgeFrame,
  type BridgeFrame,
} from '../src/protocol.ts'

const CLIENT_CAPS = {
  client: 'sketchup-ruby' as const,
  protocol: 1 as const,
  instanceId: 'sketchup-test-1',
  sketchupVersion: '24.0',
  rubyVersion: '3.2.2',
  features: ['snapshot', 'history'],
}

const HOST_CAPS = {
  protocol: 1 as const,
  historyEvents: 200,
  eventPayloadBytes: 65536,
  pluginWriteEnabled: false,
  pluginLoadEnabled: false,
}

describe('SketchUp bridge protocol', () => {
  it('parses valid client and server frames', () => {
    const hello = parseBridgeFrame(JSON.stringify({ t: 'hello', caps: CLIENT_CAPS }))!
    const event = parseBridgeFrame(JSON.stringify({
      t: 'event', seq: 3, at: 123.5, name: 'transaction.commit', payload: { count: 2 },
    }))!
    const call = parseBridgeFrame(JSON.stringify({
      t: 'tool.call', id: 'call-1', name: 'sketchup_snapshot', args: {}, expiresAt: 9999,
    }))!
    const ack = parseBridgeFrame(JSON.stringify({ t: 'hello.ok', caps: HOST_CAPS }))!

    expect(hello).toEqual({ t: 'hello', caps: CLIENT_CAPS })
    expect(SKETCHUP_BRIDGE_ORIGIN).toBe('sketchup://dsh-bridge')
    expect(event).toMatchObject({ t: 'event', name: 'transaction.commit' })
    expect(call).toMatchObject({ t: 'tool.call', name: 'sketchup_snapshot' })
    expect(ack).toMatchObject({ t: 'hello.ok', caps: HOST_CAPS })
    expect(isClientFrame(hello)).toBe(true)
    expect(isClientFrame(event)).toBe(true)
    expect(isServerFrame(call)).toBe(true)
    expect(isServerFrame(ack)).toBe(true)
  })

  it('rejects malformed frames without throwing', () => {
    const invalid = [
      '',
      'not-json',
      JSON.stringify({ t: 'hello', caps: { protocol: 1 } }),
      JSON.stringify({ t: 'event', seq: -1, at: 1, name: 'x', payload: {} }),
      JSON.stringify({ t: 'tool.call', id: 'x', name: 'x', args: [], expiresAt: 1 }),
      JSON.stringify({ t: 'tool.result', id: 'x', ok: false, error: { code: 'x' } }),
    ]
    for (const text of invalid) expect(parseBridgeFrame(text)).toBeUndefined()
  })

  it('keeps the discriminated union narrow for parsed frames', () => {
    const frames: BridgeFrame[] = [
      { t: 'hello', caps: CLIENT_CAPS },
      { t: 'hello.ok', caps: HOST_CAPS },
    ]
    expect(frames.filter(isClientFrame)).toHaveLength(1)
    expect(frames.filter(isServerFrame)).toHaveLength(1)
  })
})
