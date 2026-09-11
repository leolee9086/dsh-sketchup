import { createServer, type Server } from 'node:http'
import { runInNewContext } from 'node:vm'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'
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

// Execute the actual injected prelude, including the generated core-js source,
// with a controllable network and native socket boundary. No app build is needed.
function startPrelude(options: {
  bind?: (sessionId: string) => Response | Promise<Response>
  rpc?: () => Response | Promise<Response>
  status?: () => Response | Promise<Response>
  loading?: boolean
} = {}) {
  class FakeSocket extends EventTarget {
    readonly sent: unknown[] = []
    readonly closed: { code?: number; reason?: string }[] = []
    readyState = 1
    sendError: Error | undefined

    constructor(readonly url = 'ws://127.0.0.1:3080/api/remote.mux') { super() }

    send(data: unknown): void {
      if (this.readyState === 0) throw new Error('socket is connecting')
      if (this.readyState !== 1) return
      if (this.sendError) throw this.sendError
      this.sent.push(data)
    }

    close(code?: number, reason?: string): void {
      this.closed.push({ ...(code === undefined ? {} : { code }), ...(reason === undefined ? {} : { reason }) })
      this.readyState = 3
      this.dispatchEvent(new Event('close'))
    }
  }
  const calls: { path: string; body: unknown }[] = []
  const strip = { id: '', textContent: '', title: '', style: { cssText: '' } }
  let mounted = false
  let poll: (() => Promise<void>) | undefined
  const loaded: (() => void)[] = []
  const nativeFetch: typeof fetch = (input, init) => {
    const rawUrl = input instanceof Request ? input.url : String(input)
    const url = new URL(rawUrl, 'http://127.0.0.1:3080/')
    const body = typeof init?.body === 'string' ? JSON.parse(init.body) as { sessionId: string } : null
    calls.push({ path: url.pathname, body })
    if (url.pathname === SKETCHUP_SESSION_BIND_PATH) {
      return Promise.resolve(options.bind ? options.bind(body!.sessionId) : bindingAck(body!.sessionId))
    }
    if (url.pathname === '/ext/sketchup-instance-status') {
      return Promise.resolve(options.status ? options.status() : Response.json({ connected: true }))
    }
    return Promise.resolve(options.rpc ? options.rpc() : Response.json({ ok: true }))
  }
  const window = {
    name: `dsh-sketchup:${INSTANCE_ID}`,
    navigator: { onLine: true },
    fetch: nativeFetch,
    WebSocket: FakeSocket,
    dispatchEvent: () => true,
    setInterval: (callback: () => Promise<void>) => { poll = callback },
  }
  const script = injectSurfacePrelude('<html><head></head><body></body></html>')
    .match(/<script data-dsh-sketchup-surface>([\s\S]*)<\/script>/)?.[1]
  if (!script) throw new Error('surface prelude missing')
  runInNewContext(script, {
    window, URL, Request, setTimeout, clearTimeout, setImmediate, queueMicrotask, console,
    location: new URL('http://127.0.0.1:3080/'),
    CustomEvent: class { constructor(readonly type: string) {} },
    document: {
      readyState: options.loading ? 'loading' : 'complete',
      documentElement: { setAttribute: () => undefined },
      createElement: () => strip,
      getElementById: () => mounted ? strip : null,
      addEventListener: (_type: string, callback: () => void) => { loaded.push(callback) },
      body: { appendChild: () => { mounted = true } },
    },
  })
  return {
    window, FakeSocket, calls, strip,
    poll: () => poll!(),
    load: () => { for (const callback of loaded) callback() },
    rpc: (sessionId = 'session-one') => window.fetch('/api/session/send', {
      method: 'POST', body: JSON.stringify({ args: { sessionId } }),
    }),
  }
}

function bindingAck(sessionId = 'session-one'): Response {
  return Response.json({ ok: true, sessionId, instanceId: INSTANCE_ID })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((nextResolve, nextReject) => { resolve = nextResolve; reject = nextReject })
  return { promise, resolve, reject }
}

// Drain both host and vm Promise continuations without polling or timeouts.
const flushPrelude = () => new Promise<void>(resolve => setImmediate(resolve))
const openFrame = (streamId = 'stream-one', sessionId = 'session-one') => JSON.stringify({
  type: 'open', streamId, endpoint: 'session/follow', payload: { args: { sessionId } },
})

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
    const runtimePromise = runInNewContext(script + '; Promise', {
      AbortController: LegacyAbortController,
      AbortSignal: LegacySignal,
      CustomEvent: LegacyCustomEvent,
      Promise: LegacyPromise,
      document,
      window,
    })

    const withResolvers = Reflect.get(runtimePromise, 'withResolvers') as () => {
      promise: Promise<string>
      resolve: (value: string) => void
      reject: (reason?: unknown) => void
    }
    expect(withResolvers).toBeTypeOf('function')
    const gate = withResolvers.call(runtimePromise)
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

  it.each([401, 403, 404, 500])('blocks RPC when binding returns HTTP %s and allows a later retry', async status => {
    const bind = vi.fn().mockImplementationOnce(() => Response.json({ error: 'failed' }, { status }))
      .mockImplementation(() => bindingAck())
    const runtime = startPrelude({ bind })
    await expect(runtime.rpc()).rejects.toThrow(`HTTP ${status}`)
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(0)
    await expect(runtime.rpc()).resolves.toBeInstanceOf(Response)
    expect(bind).toHaveBeenCalledTimes(2)
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(1)
  })

  it.each(['network', 'synchronous fetch', 'invalid JSON', 'wrong instance', 'wrong session', 'not acknowledged'])(
    'blocks RPC on %s binding failure', async failure => {
      const runtime = startPrelude({ bind: () => {
        if (failure === 'synchronous fetch') throw new Error('offline')
        if (failure === 'network') return Promise.reject(new Error('offline'))
        if (failure === 'invalid JSON') return new Response('<html>login</html>')
        return Response.json({
          ok: failure !== 'not acknowledged',
          sessionId: failure === 'wrong session' ? 'session-other' : 'session-one',
          instanceId: failure === 'wrong instance' ? 'sketchup-other' : INSTANCE_ID,
        })
      } })
      await expect(runtime.rpc()).rejects.toThrow()
      expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(0)
    },
  )

  it('coalesces concurrent binds but rebinds before every later RPC', async () => {
    const gate = deferred<Response>()
    const bind = vi.fn().mockImplementationOnce(() => gate.promise).mockImplementation(() => bindingAck())
    const runtime = startPrelude({ bind })
    const first = runtime.rpc()
    const second = runtime.rpc()
    await flushPrelude()
    expect(bind).toHaveBeenCalledTimes(1)
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(0)
    gate.resolve(bindingAck())
    await Promise.all([first, second])
    await runtime.rpc()
    expect(bind).toHaveBeenCalledTimes(2)
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(3)
  })

  it('rejects every waiting RPC after a shared binding failure and retries cleanly', async () => {
    const gate = deferred<Response>()
    const bind = vi.fn().mockImplementationOnce(() => gate.promise).mockImplementation(() => bindingAck())
    const runtime = startPrelude({ bind })
    const settled = Promise.allSettled([runtime.rpc(), runtime.rpc()])
    await flushPrelude()
    gate.reject(new Error('connection lost'))
    expect((await settled).map(result => result.status)).toEqual(['rejected', 'rejected'])
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(0)
    await runtime.rpc()
    expect(bind).toHaveBeenCalledTimes(2)
  })

  it('rechecks a formerly successful binding and blocks after the instance disappears', async () => {
    const bind = vi.fn().mockImplementationOnce(() => bindingAck())
      .mockImplementation(() => Response.json({ error: 'gone' }, { status: 404 }))
    const runtime = startPrelude({ bind })
    await runtime.rpc()
    await expect(runtime.rpc()).rejects.toThrow('HTTP 404')
    expect(runtime.calls.filter(call => call.path === '/api/session/send')).toHaveLength(1)
  })

  it('propagates binding failure after create instead of returning an unbound session', async () => {
    const runtime = startPrelude({
      rpc: () => Response.json({ result: { sessionId: 'created-session' } }),
      bind: () => Response.json({ error: 'gone' }, { status: 404 }),
    })
    await expect(runtime.window.fetch('/api/session/create', { method: 'POST', body: '{}' })).rejects.toThrow('HTTP 404')
    expect(runtime.calls.filter(call => call.path === SKETCHUP_SESSION_BIND_PATH)[0]?.body)
      .toEqual({ sessionId: 'created-session', instanceId: INSTANCE_ID })
  })

  it('binds created sessions and leaves the successful response readable', async () => {
    const runtime = startPrelude({ rpc: () => Response.json({ sessionId: 'created-session' }) })
    const response = await runtime.window.fetch('/api/session/create', { method: 'POST', body: '{}' })
    expect(await response.json()).toEqual({ sessionId: 'created-session' })
    expect(runtime.calls.filter(call => call.path === SKETCHUP_SESSION_BIND_PATH)).toHaveLength(1)
  })

  it('recognizes Request and URL inputs without consuming the original Request body', async () => {
    const runtime = startPrelude()
    const request = new Request('http://127.0.0.1:3080/api/session/send', {
      method: 'POST', body: JSON.stringify({ sessionId: 'session-one' }),
    })
    await runtime.window.fetch(request)
    expect(await request.json()).toEqual({ sessionId: 'session-one' })
    await runtime.window.fetch(new URL(request.url), { method: 'POST', body: JSON.stringify({ sessionId: 'session-two' }) })
    expect(runtime.calls.filter(call => call.path === SKETCHUP_SESSION_BIND_PATH).map(call => call.body)).toEqual([
      { sessionId: 'session-one', instanceId: INSTANCE_ID },
      { sessionId: 'session-two', instanceId: INSTANCE_ID },
    ])
  })

  it('does not bind requests or sockets on unrelated origins or routes', async () => {
    const runtime = startPrelude()
    await runtime.window.fetch('https://example.com/api/session/send', {
      method: 'POST', body: JSON.stringify({ sessionId: 'external-session' }),
    })
    await runtime.window.fetch('/api/other/send', { method: 'POST', body: JSON.stringify({ sessionId: 'other-session' }) })
    for (const url of ['wss://example.com/api/remote.mux', 'ws://127.0.0.1:3080/other']) {
      const socket = new runtime.FakeSocket(url)
      socket.send(openFrame())
      expect(socket.sent).toEqual([openFrame()])
    }
    expect(runtime.calls.filter(call => call.path === SKETCHUP_SESSION_BIND_PATH)).toHaveLength(0)
  })

  it('holds mux data behind its open while unrelated streams pass through', async () => {
    const gate = deferred<Response>()
    const runtime = startPrelude({ bind: () => gate.promise })
    const socket = new runtime.FakeSocket()
    const data = JSON.stringify({ type: 'data', streamId: 'stream-one', value: 1 })
    const unrelated = JSON.stringify({ type: 'open', streamId: 'events', endpoint: '$events', payload: {} })
    socket.send(openFrame())
    socket.send(data)
    socket.send(unrelated)
    expect(socket.sent).toEqual([unrelated])
    gate.resolve(bindingAck())
    await flushPrelude()
    expect(socket.sent).toEqual([unrelated, openFrame(), data])
  })

  it.each(['success', 'failure'])('discards canceled mux opens after binding %s', async outcome => {
    const gate = deferred<Response>()
    const runtime = startPrelude({ bind: () => gate.promise })
    const socket = new runtime.FakeSocket()
    socket.send(openFrame())
    socket.send(JSON.stringify({ type: 'data', streamId: 'stream-one', value: 1 }))
    socket.send(JSON.stringify({ type: 'cancel', streamId: 'stream-one' }))
    await flushPrelude()
    if (outcome === 'success') gate.resolve(bindingAck())
    else gate.reject(new Error('offline'))
    await flushPrelude()
    expect(socket.sent).toEqual([])
    expect(socket.closed).toEqual([])
  })

  it.each([2, 3])('never sends a delayed mux open when the carrier readyState is %s', async readyState => {
    const gate = deferred<Response>()
    const runtime = startPrelude({ bind: () => gate.promise })
    const socket = new runtime.FakeSocket()
    socket.send(openFrame())
    if (readyState === 3) socket.close()
    else socket.readyState = readyState
    gate.resolve(bindingAck())
    await flushPrelude()
    expect(socket.sent).toEqual([])
  })

  it.each(['HTTP', 'network', 'send'])('fails the mux carrier without sending an unbound open on %s failure', async failure => {
    const runtime = startPrelude({ bind: () => {
      if (failure === 'network') return Promise.reject(new Error('offline'))
      return failure === 'HTTP' ? Response.json({ error: 'gone' }, { status: 404 }) : bindingAck()
    } })
    const socket = new runtime.FakeSocket()
    if (failure === 'send') socket.sendError = new Error('native send failed')
    socket.send(openFrame())
    await flushPrelude()
    expect(socket.sent).toEqual([])
    expect(socket.closed).toEqual([{ code: 4003, reason: 'WebView session binding failed' }])
  })

  it('keeps cancellation local to its socket and rebinds new mux streams', async () => {
    const gate = deferred<Response>()
    const bind = vi.fn().mockImplementationOnce(() => gate.promise).mockImplementation(() => bindingAck())
    const runtime = startPrelude({ bind })
    const first = new runtime.FakeSocket()
    const second = new runtime.FakeSocket()
    first.send(openFrame())
    second.send(openFrame())
    first.send(JSON.stringify({ type: 'cancel', streamId: 'stream-one' }))
    gate.resolve(bindingAck())
    await flushPrelude()
    expect(first.sent).toEqual([])
    expect(second.sent).toEqual([openFrame()])
    second.send(openFrame('stream-two'))
    await flushPrelude()
    expect(bind).toHaveBeenCalledTimes(2)
    expect(second.sent).toEqual([openFrame(), openFrame('stream-two')])
    const cancel = JSON.stringify({ type: 'cancel', streamId: 'stream-two' })
    second.send(cancel)
    expect(second.sent.at(-1)).toBe(cancel)
  })

  it.each(['404', '401', 'network', 'malformed', 'missing connected', 'false'])(
    'clears the connected label on status %s and recovers on success', async failure => {
      let fail = false
      const runtime = startPrelude({ status: () => {
        if (!fail) return Response.json({ connected: true })
        if (failure === 'network') return Promise.reject(new Error('offline'))
        if (failure === 'malformed') return new Response('invalid JSON')
        if (failure === '404' || failure === '401') return Response.json({ error: 'gone' }, { status: Number(failure) })
        return Response.json(failure === 'false' ? { connected: false } : {})
      } })
      await flushPrelude()
      expect(runtime.strip.textContent).toBe('SketchUp - surface-')
      fail = true
      await runtime.poll()
      expect(runtime.strip.textContent).toBe('SketchUp - disconnected')
      fail = false
      await runtime.poll()
      expect(runtime.strip.textContent).toBe('SketchUp - surface-')
    },
  )

  it('renders an early disconnected status when the document finishes loading', async () => {
    const runtime = startPrelude({ loading: true, status: () => Response.json({ error: 'gone' }, { status: 404 }) })
    await flushPrelude()
    runtime.load()
    expect(runtime.strip.textContent).toBe('SketchUp - disconnected')
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
