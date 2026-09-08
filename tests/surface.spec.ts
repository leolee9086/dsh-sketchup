import { createServer, type Server } from 'node:http'
import { runInNewContext } from 'node:vm'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import WebSocket from 'ws'
import type { Context } from '@deepseek-ai/cordis'
import {
  SKETCHUP_BRIDGE_ORIGIN,
  SKETCHUP_SESSION_BIND_PATH,
} from '../src/protocol.ts'
import { SketchupBridgeServer } from '../src/server.ts'
import { injectSurfacePrelude, registerSketchupSurface } from '../src/surface.ts'

const INSTANCE_ID = 'sketchup-surface-1'
const CLIENT_CAPS = {
  client: 'sketchup-ruby' as const,
  protocol: 1 as const,
  instanceId: INSTANCE_ID,
  features: ['snapshot'],
}

interface Route {
  handler: (req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse) => void | Promise<void>
}

interface SurfaceHarness {
  bridge: SketchupBridgeServer
  server: Server
  baseUrl: string
  dispose: () => void
}

const harnesses: SurfaceHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    harness.dispose()
    await harness.bridge.close()
    await new Promise<void>((resolve) => harness.server.close(() => resolve()))
  }
})

async function startSurface(rejection: 401 | 403 | undefined = undefined): Promise<SurfaceHarness> {
  const routes = new Map<string, Route>()
  let tap: ((html: string) => string) | undefined
  const fakeWebServer = {
    port: 0,
    register(route: { path: string; handler: Route['handler'] }) {
      routes.set(route.path, { handler: route.handler })
      return () => { routes.delete(route.path) }
    },
    tapIndex(transform: (html: string) => string) {
      tap = transform
      return () => { if (tap === transform) tap = undefined }
    },
  }
  const fakeConnection = {
    authenticatedUrl: (baseUrl: string) => `${baseUrl}/?token=test-token`,
    requestRejection: () => rejection,
  }
  const context = {
    webServer: fakeWebServer,
    get: (name: string) => name === 'connection' ? fakeConnection : undefined,
  } as unknown as Context
  const bridge = new SketchupBridgeServer({
    toolTimeoutMs: 1_000,
    maxHistoryEvents: 20,
    maxEventPayloadBytes: 256,
    pluginWriteEnabled: false,
    pluginLoadEnabled: false,
  })
  const server = createServer((req, res) => {
    const pathname = new URL(req.url ?? '/', 'http://127.0.0.1').pathname
    const route = routes.get(pathname)
    if (route === undefined) {
      res.writeHead(404)
      res.end()
      return
    }
    void route.handler(req, res)
  })
  server.on('upgrade', (req, socket, head) => bridge.handleUpgrade(req, socket, head))
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  fakeWebServer.port = port
  const dispose = registerSketchupSurface(context, bridge)
  const harness = { bridge, server, baseUrl: `http://127.0.0.1:${port}`, dispose }
  harnesses.push(harness)
  // The variable is intentionally read to ensure the fake exposes the same
  // index-tap lifecycle as the real WebServer.
  expect(tap).toBeTypeOf('function')
  return harness
}

async function handshake(baseUrl: string): Promise<WebSocket> {
  const ws = new WebSocket(`${baseUrl.replace('http', 'ws')}/ext/sketchup`, {
    headers: { origin: SKETCHUP_BRIDGE_ORIGIN },
  })
  await new Promise<void>((resolve, reject) => {
    ws.once('open', () => resolve())
    ws.once('error', reject)
  })
  ws.send(JSON.stringify({ t: 'hello', caps: CLIENT_CAPS }))
  await new Promise<void>((resolve, reject) => {
    const onMessage = (data: WebSocket.RawData) => {
      const frame = JSON.parse(data.toString()) as { t?: string }
      if (frame.t === 'hello.ok') {
        ws.off('message', onMessage)
        resolve()
      }
    }
    ws.on('message', onMessage)
    ws.once('error', reject)
  })
  return ws
}

describe('SketchUp WebView surface', () => {
  it('injects one identity prelude before the DSH app module', () => {
    const html = '<!doctype html><html><head></head><body><div id="root"></div></body></html>'
    const injected = injectSurfacePrelude(html)
    expect(injected).toContain('data-dsh-sketchup-surface')
    expect(injected).toContain('/ext/sketchup-session-bind')
    expect(injected).toContain('input instanceof URL')
    expect(injected).toContain('/api/remote.mux')
    expect(injected).toContain('const instanceIdPrefix = "sketchup-"')
    expect(injected).toContain('shortInstanceId')
    expect(injected).toContain('navigator.onLine')
    expect(injected).toContain("new Event('online')")
    expect(injected).not.toContain('${INSTANCE_ID_PATTERN.toString()}')
    expect(injectSurfacePrelude(injected)).toBe(injected)

    const generic = injectSurfacePrelude(html, {
      launchPath: '/ext/host-chat',
      bindPath: '/ext/host-bind',
      statusPath: '/ext/host-status',
      windowPrefix: 'dsh-host:',
      surfaceId: 'host',
      instanceIdPrefix: 'host-',
      label: 'Host',
    })
    expect(generic).toContain('/ext/host-bind')
    expect(generic).toContain('const label = "Host"')
    expect(generic).toContain('const instanceIdPrefix = "host-"')
    expect(generic).toContain("const surfaceId = \"host\"")
    expect(generic).not.toContain('/ext/sketchup-session-bind')
  })

  it('installs compatibility shims when an embedded WebView lacks current APIs', async () => {
    const html = '<!doctype html><html><head></head><body></body></html>'
    const injected = injectSurfacePrelude(html)
    const script = injected.match(/<script data-dsh-sketchup-surface>([\s\S]*)<\/script>/)?.[1]
    expect(script).toBeDefined()

    class LegacyPromise<T> extends Promise<T> {}
    Reflect.defineProperty(LegacyPromise, 'withResolvers', {
      configurable: true,
      writable: true,
      value: undefined,
    })
    class LegacySignal {
      private readonly listeners = new Set<() => void>()
      aborted = false
      reason: unknown = undefined

      addEventListener(type: string, listener: () => void): void {
        if (type === 'abort') this.listeners.add(listener)
      }

      removeEventListener(type: string, listener: () => void): void {
        if (type === 'abort') this.listeners.delete(listener)
      }

      dispatchAbort(reason: unknown): void {
        if (this.aborted) return
        this.aborted = true
        this.reason = reason
        for (const listener of [...this.listeners]) listener()
      }
    }
    class LegacyAbortController {
      readonly signal = new LegacySignal()

      abort(reason?: unknown): void {
        this.signal.dispatchAbort(reason)
      }
    }
    class LegacyCustomEvent {
      constructor(readonly type: string, readonly init?: unknown) {}
    }
    const document = {
      readyState: 'loading',
      documentElement: { setAttribute: () => undefined },
      addEventListener: () => undefined,
      getElementById: () => null,
    }
    const window = {
      name: `dsh-sketchup:${INSTANCE_ID}`,
      navigator: { onLine: true },
      fetch: async () => ({ json: async () => ({ connected: true }) }),
      dispatchEvent: () => true,
    }
    runInNewContext(script, {
      AbortController: LegacyAbortController,
      AbortSignal: LegacySignal,
      CustomEvent: LegacyCustomEvent,
      Promise: LegacyPromise,
      document,
      window,
    })

    const withResolvers = Reflect.get(LegacyPromise, 'withResolvers') as () => {
      promise: Promise<string>
      resolve: (value: string) => void
      reject: (reason?: unknown) => void
    }
    expect(withResolvers).toBeTypeOf('function')
    const gate = withResolvers.call(LegacyPromise)
    gate.resolve('ready')
    await expect(gate.promise).resolves.toBe('ready')

    const any = Reflect.get(LegacySignal, 'any') as (signals: Iterable<LegacySignal>) => LegacySignal
    expect(any).toBeTypeOf('function')
    const first = new LegacyAbortController()
    const second = new LegacyAbortController()
    const combined = any([first.signal, second.signal])
    second.abort('second reason')
    first.abort('later reason')
    expect(combined.aborted).toBe(true)
    expect(combined.reason).toBe('second reason')
  })

  it('launches with the standard authenticated DSH URL and preserves instance identity', async () => {
    const harness = await startSurface()
    const ws = await handshake(harness.baseUrl)
    const response = await fetch(`${harness.baseUrl}/ext/sketchup-chat?instanceId=${INSTANCE_ID}`)
    const body = await response.text()
    expect(response.status).toBe(200)
    expect(response.headers.get('cache-control')).toBe('no-store')
    expect(body).toContain(`dsh-sketchup:${INSTANCE_ID}`)
    expect(body).toContain('token=test-token')
    ws.close()
  })

  it('rejects a launch for an unknown instance before minting a URL', async () => {
    const harness = await startSurface()
    const response = await fetch(`${harness.baseUrl}/ext/sketchup-chat?instanceId=sketchup-missing`)
    expect(response.status).toBe(409)
    expect(await response.json()).toMatchObject({ error: expect.stringContaining('not connected') })
  })

  it('authenticates binding and binds a Session to the connected instance', async () => {
    const harness = await startSurface()
    const ws = await handshake(harness.baseUrl)
    const response = await fetch(`${harness.baseUrl}${SKETCHUP_SESSION_BIND_PATH}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: 'session-surface', instanceId: INSTANCE_ID }),
    })
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ ok: true, sessionId: 'session-surface', instanceId: INSTANCE_ID })
    expect(harness.bridge.status()).toMatchObject({ instanceCount: 1 })
    ws.close()
  })

  it('returns authenticated all-instance and one-instance status views', async () => {
    const harness = await startSurface()
    const ws = await handshake(harness.baseUrl)
    const all = await fetch(`${harness.baseUrl}/ext/sketchup-instance-status`)
    expect(all.status).toBe(200)
    expect(await all.json()).toMatchObject({
      instances: [{ instanceId: INSTANCE_ID, connected: true }],
    })

    const one = await fetch(`${harness.baseUrl}/ext/sketchup-instance-status?instanceId=${INSTANCE_ID}`)
    expect(one.status).toBe(200)
    expect(await one.json()).toMatchObject({ instanceId: INSTANCE_ID, connected: true })

    const missing = await fetch(`${harness.baseUrl}/ext/sketchup-instance-status?instanceId=sketchup-missing`)
    expect(missing.status).toBe(404)
    expect(await missing.json()).toMatchObject({ error: expect.stringContaining('not connected') })
    ws.close()
  })

  it('enforces methods on surface routes', async () => {
    const harness = await startSurface()
    const ws = await handshake(harness.baseUrl)
    const launch = await fetch(`${harness.baseUrl}/ext/sketchup-chat?instanceId=${INSTANCE_ID}`, { method: 'POST' })
    const bind = await fetch(`${harness.baseUrl}${SKETCHUP_SESSION_BIND_PATH}`, { method: 'GET' })
    expect(launch.status).toBe(405)
    expect(bind.status).toBe(405)
    ws.close()
  })

  it('rejects unauthenticated binding and status requests', async () => {
    const harness = await startSurface(401)
    const bind = await fetch(`${harness.baseUrl}${SKETCHUP_SESSION_BIND_PATH}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: 'session-surface', instanceId: INSTANCE_ID }),
    })
    const status = await fetch(`${harness.baseUrl}/ext/sketchup-instance-status`)
    expect(bind.status).toBe(401)
    expect(status.status).toBe(401)
  })
})
