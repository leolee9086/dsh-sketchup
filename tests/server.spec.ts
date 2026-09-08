import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import WebSocket from 'ws'
import {
  SKETCHUP_BRIDGE_ORIGIN,
  type BridgeFrame,
} from '../src/protocol.ts'
import {
  SketchupBridgeError,
  SketchupBridgeServer,
  isLoopbackAddress,
} from '../src/server.ts'

const CLIENT_CAPS = {
  client: 'sketchup-ruby' as const,
  protocol: 1 as const,
  instanceId: 'sketchup-test-1',
  features: ['snapshot', 'history'],
}

interface Harness {
  bridge: SketchupBridgeServer
  http: Server
  url: string
}

const harnesses: Harness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.bridge.close()
    await new Promise<void>((resolve) => harness.http.close(() => resolve()))
  }
})

async function startBridge(
  overrides: Partial<ConstructorParameters<typeof SketchupBridgeServer>[0]> = {},
): Promise<Harness> {
  const bridge = new SketchupBridgeServer({
    toolTimeoutMs: 1_000,
    maxHistoryEvents: 20,
    maxEventPayloadBytes: 256,
    pluginWriteEnabled: false,
    pluginLoadEnabled: false,
    ...overrides,
  })
  const http = createServer()
  http.on('upgrade', (request, socket, head) => bridge.handleUpgrade(request, socket, head))
  await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve))
  const port = (http.address() as AddressInfo).port
  const harness = { bridge, http, url: `ws://127.0.0.1:${port}/ext/sketchup` }
  harnesses.push(harness)
  return harness
}

function connect(url: string, origin: string | undefined = SKETCHUP_BRIDGE_ORIGIN): Promise<{ ws: WebSocket; frames: BridgeFrame[] }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, origin === undefined ? undefined : { headers: { origin } })
    const frames: BridgeFrame[] = []
    ws.on('message', (data) => {
      const frame = JSON.parse(data.toString()) as BridgeFrame
      frames.push(frame)
    })
    ws.once('error', reject)
    ws.once('open', () => resolve({ ws, frames }))
  })
}

function send(ws: WebSocket, frame: BridgeFrame): void {
  ws.send(JSON.stringify(frame))
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const started = Date.now()
  while (!predicate()) {
    if (Date.now() - started > timeoutMs) throw new Error('waitFor timed out')
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

async function handshake(
  harness: Harness,
  caps: typeof CLIENT_CAPS = CLIENT_CAPS,
): Promise<{ ws: WebSocket; frames: BridgeFrame[] }> {
  const client = await connect(harness.url)
  send(client.ws, { t: 'hello', caps })
  await waitFor(() => client.frames.some((frame) => frame.t === 'hello.ok'))
  return client
}

describe('SketchupBridgeServer', () => {
  it('recognizes only loopback addresses', () => {
    expect(isLoopbackAddress('127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('::1')).toBe(true)
    expect(isLoopbackAddress('::ffff:127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('192.168.1.10')).toBe(false)
    expect(isLoopbackAddress(undefined)).toBe(false)
  })

  it('accepts the native local handshake and advertises the safety caps', async () => {
    const harness = await startBridge()
    const client = await handshake(harness)
    expect(client.frames).toContainEqual({
      t: 'hello.ok',
      caps: {
        protocol: 1,
        historyEvents: 20,
        eventPayloadBytes: 256,
        pluginWriteEnabled: false,
        pluginLoadEnabled: false,
      },
    })
    client.ws.close()
  })

  it('rejects a browser origin and a non-loopback upgrade', async () => {
    const harness = await startBridge()
    await expect(connect(harness.url, 'https://example.test')).rejects.toBeDefined()

    const remote = await startBridge({ remoteAddressOverride: '192.168.1.10' })
    const rejected = await connect(remote.url).catch(() => undefined)
    expect(rejected).toBeUndefined()
  })

  it('records bounded event frames and exposes status/history', async () => {
    const harness = await startBridge()
    const client = await handshake(harness)
    send(client.ws, { t: 'event', seq: 1, at: 10, name: 'transaction.commit', payload: { ok: true } })
    send(client.ws, { t: 'event', seq: 2, at: 11, name: 'large', payload: 'x'.repeat(400) })
    await waitFor(() => harness.bridge.history().length === 2)
    expect(harness.bridge.history()).toEqual([
      { instanceId: 'sketchup-test-1', seq: 1, at: 10, name: 'transaction.commit', payload: { ok: true } },
      { instanceId: 'sketchup-test-1', seq: 2, at: 11, name: 'large', payload: { truncated: true, bytes: 402 } },
    ])
    expect(harness.bridge.status()).toMatchObject({ connected: true, historyEvents: 2 })
    harness.bridge.clearHistory()
    expect(harness.bridge.history()).toEqual([])
    client.ws.close()
  })

  it('dispatches a tool call and resolves its result', async () => {
    const harness = await startBridge()
    const client = await handshake(harness)
    const pending = harness.bridge.requestTool('sketchup_snapshot', {}, new AbortController().signal)
    await waitFor(() => client.frames.some((frame) => frame.t === 'tool.call'))
    const call = client.frames.find((frame): frame is Extract<BridgeFrame, { t: 'tool.call' }> => frame.t === 'tool.call')!
    expect(call.name).toBe('sketchup_snapshot')
    send(client.ws, { t: 'tool.result', id: call.id, ok: true, result: { text: 'snapshot' } })
    await expect(pending).resolves.toEqual({ text: 'snapshot' })
    client.ws.close()
  })

  it('cancels timed-out calls and rejects pre-aborted calls', async () => {
    const harness = await startBridge()
    const client = await handshake(harness)
    const pending = harness.bridge.requestTool('sketchup_execute', {}, new AbortController().signal, 25)
    await expect(pending).rejects.toMatchObject({ code: 'timeout' })
    await waitFor(() => client.frames.some((frame) => frame.t === 'tool.cancel'))

    const controller = new AbortController()
    controller.abort()
    expect(() => harness.bridge.requestTool('sketchup_execute', {}, controller.signal))
      .toThrowError(expect.objectContaining({ code: 'bridge-closed' }))
    client.ws.close()
  })

  it('settles pending calls when a second client replaces the first', async () => {
    const harness = await startBridge()
    const first = await handshake(harness)
    const pending = harness.bridge.requestTool('sketchup_query', {}, new AbortController().signal)
    const assertion = expect(pending).rejects.toMatchObject({ code: 'bridge-closed' })
    await waitFor(() => first.frames.some((frame) => frame.t === 'tool.call'))

    const second = await handshake(harness)
    await assertion
    expect(harness.bridge.hasConnection()).toBe(true)
    first.ws.close()
    second.ws.close()
  })

  it('keeps distinct instances routable and rejects ambiguous implicit calls', async () => {
    const harness = await startBridge()
    const first = await handshake(harness)
    const second = await handshake(harness, { ...CLIENT_CAPS, instanceId: 'sketchup-test-2' })
    expect(harness.bridge.status()).toMatchObject({ connected: true, instanceCount: 2 })
    expect(harness.bridge.instances().map(item => item.instanceId)).toEqual([
      'sketchup-test-1',
      'sketchup-test-2',
    ])

    expect(() => harness.bridge.requestTool('sketchup_snapshot', {}, new AbortController().signal))
      .toThrowError(expect.objectContaining({ code: 'ambiguous' }))

    harness.bridge.bindSession('session-two', 'sketchup-test-2')
    const pending = harness.bridge.requestTool(
      'sketchup_snapshot',
      {},
      new AbortController().signal,
      1_000,
      'session-two',
    )
    await waitFor(() => second.frames.some(frame => frame.t === 'tool.call'))
    expect(first.frames.some(frame => frame.t === 'tool.call')).toBe(false)
    const call = second.frames.find((frame): frame is Extract<BridgeFrame, { t: 'tool.call' }> => frame.t === 'tool.call')!
    send(second.ws, { t: 'tool.result', id: call.id, ok: true, result: { text: 'second' } })
    await expect(pending).resolves.toEqual({ text: 'second' })

    first.ws.close()
    second.ws.close()
  })

  it('keeps history and bindings scoped to the selected instance', async () => {
    const harness = await startBridge()
    const first = await handshake(harness)
    const second = await handshake(harness, { ...CLIENT_CAPS, instanceId: 'sketchup-test-2' })
    send(first.ws, { t: 'event', seq: 1, at: 10, name: 'first.event', payload: { source: 1 } })
    send(second.ws, { t: 'event', seq: 1, at: 11, name: 'second.event', payload: { source: 2 } })
    await waitFor(() => harness.bridge.history(20, 'sketchup-test-2').length === 1)
    expect(harness.bridge.history(20, 'sketchup-test-1')).toEqual([
      { instanceId: 'sketchup-test-1', seq: 1, at: 10, name: 'first.event', payload: { source: 1 } },
    ])
    expect(harness.bridge.history(20, 'sketchup-test-2')).toEqual([
      { instanceId: 'sketchup-test-2', seq: 1, at: 11, name: 'second.event', payload: { source: 2 } },
    ])
    harness.bridge.bindSession('session-one', 'sketchup-test-1')
    first.ws.close()
    await waitFor(() => harness.bridge.status().instanceCount === 1)
    await expect(Promise.resolve().then(() => harness.bridge.requestTool(
      'sketchup_snapshot',
      {},
      new AbortController().signal,
      1_000,
      'session-one',
    ))).rejects.toMatchObject({ code: 'unknown-instance' })
    expect(second.frames.some(frame => frame.t === 'tool.call')).toBe(false)
    second.ws.close()
  })

  it('retains a Session binding across same-instance reconnects', async () => {
    const harness = await startBridge()
    const first = await handshake(harness)
    harness.bridge.bindSession('session-reconnect', 'sketchup-test-1')
    first.ws.close()
    await waitFor(() => harness.bridge.status().instanceCount === 0)

    const second = await handshake(harness)
    const pending = harness.bridge.requestTool(
      'sketchup_snapshot',
      {},
      new AbortController().signal,
      1_000,
      'session-reconnect',
    )
    await waitFor(() => second.frames.some(frame => frame.t === 'tool.call'))
    const call = second.frames.find((frame): frame is Extract<BridgeFrame, { t: 'tool.call' }> => frame.t === 'tool.call')!
    send(second.ws, { t: 'tool.result', id: call.id, ok: true, result: { text: 'reconnected' } })
    await expect(pending).resolves.toEqual({ text: 'reconnected' })
    second.ws.close()
  })

  it('reports no connection and closes idempotently', async () => {
    const harness = await startBridge()
    expect(() => harness.bridge.requestTool('sketchup_status', {}, new AbortController().signal))
      .toThrowError(new SketchupBridgeError('bridge-closed', 'no SketchUp client is connected'))
    await harness.bridge.close()
    await harness.bridge.close()
  })
})
