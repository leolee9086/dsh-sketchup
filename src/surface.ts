/**
 * Reusable authenticated WebView surface for SketchUp and future native hosts.
 *
 * The launch endpoint establishes the process-token browser session using the
 * normal DSH Connection service, then redirects to the regular DSH Web app.
 * `window.name` carries the host instance identity across that redirect. A
 * small index prelude binds Session RPC traffic back to this instance without
 * replacing the DSH conversation UI or duplicating its session protocol.
 */

import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-client-connection'
import {
  INSTANCE_ID_PATTERN,
  SKETCHUP_CHAT_PATH,
  SKETCHUP_INSTANCE_STATUS_PATH,
  SKETCHUP_SESSION_BIND_PATH,
  SKETCHUP_SURFACE_WINDOW_PREFIX,
  isInstanceId,
} from './protocol.ts'
import { isLoopbackAddress, SketchupBridgeError, type SketchupBridgeServer } from './server.ts'

/** Minimal structural view of the Host Connection service. */
interface HostConnectionLike {
  authenticatedUrl(baseUrl: string): string
  requestRejection(request: IncomingMessage): 401 | 403 | undefined
}

/** Registry operations needed by a native WebView surface. */
export interface WebViewInstanceRegistry {
  hasConnection(instanceId: string): boolean
  bindSession(sessionId: string, instanceId: string): { sessionId: string; instanceId: string }
  instances(): readonly unknown[]
  instanceStatus(instanceId: string): unknown
}

/** Host-specific names and paths used by one WebView surface. */
export interface WebViewSurfaceOptions {
  /** Unauthenticated loopback launch path. */
  launchPath: string
  /** Authenticated Session-to-instance binding path. */
  bindPath: string
  /** Authenticated status path. */
  statusPath: string
  /** Prefix stored in window.name while the surface is open. */
  windowPrefix: string
  /** Stable lowercase namespace for injected DOM markers and ids. */
  surfaceId: string
  /** Optional stable id prefix removed before rendering the short identity. */
  instanceIdPrefix?: string
  /** Short label shown in the identity strip. */
  label: string
}

/** Default options for the SketchUp implementation. */
export const SKETCHUP_SURFACE_OPTIONS: WebViewSurfaceOptions = {
  launchPath: SKETCHUP_CHAT_PATH,
  bindPath: SKETCHUP_SESSION_BIND_PATH,
  statusPath: SKETCHUP_INSTANCE_STATUS_PATH,
  windowPrefix: SKETCHUP_SURFACE_WINDOW_PREFIX,
  surfaceId: 'sketchup',
  instanceIdPrefix: 'sketchup-',
  label: 'SketchUp',
}

const MAX_BODY_BYTES = 16 * 1024
const SURFACE_ID_PATTERN = /^[a-z][a-z0-9-]{0,31}$/

/**
 * Register one target-neutral authenticated WebView surface.
 *
 * A future native host can call this with its own route names and identity
 * prefix while reusing the same authentication, Session binding, and status
 * behavior. The bridge registry only needs the small interface above.
 */
export function registerWebViewSurface(
  ctx: Context,
  registry: WebViewInstanceRegistry,
  options: WebViewSurfaceOptions = SKETCHUP_SURFACE_OPTIONS,
): () => void {
  assertSurfaceOptions(options)
  const chatDisposer = ctx.webServer.register({
    kind: 'exact',
    path: options.launchPath,
    handler: (req, res) => launchSurface(ctx, registry, options, req, res),
  })
  const bindDisposer = ctx.webServer.register({
    kind: 'exact',
    path: options.bindPath,
    handler: (req, res) => bindSession(ctx, registry, req, res),
  })
  const statusDisposer = ctx.webServer.register({
    kind: 'exact',
    path: options.statusPath,
    handler: (req, res) => readInstanceStatus(ctx, registry, req, res),
  })
  const tapDisposer = ctx.webServer.tapIndex((html) => injectSurfacePrelude(html, options))
  return () => {
    tapDisposer()
    statusDisposer()
    bindDisposer()
    chatDisposer()
  }
}

/** SketchUp-named wrapper retained as the package's simple integration API. */
export function registerSketchupSurface(ctx: Context, bridge: SketchupBridgeServer): () => void {
  return registerWebViewSurface(ctx, bridge)
}

async function launchSurface(
  ctx: Context,
  registry: WebViewInstanceRegistry,
  options: WebViewSurfaceOptions,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  if (req.method !== 'GET') {
    res.writeHead(405, { allow: 'GET' })
    res.end()
    return
  }
  // The launch response contains a fresh process token. Keep this endpoint
  // reachable only from the same machine even when WebServer binds LAN.
  if (!isLoopbackAddress(req.socket.remoteAddress)) {
    writeJson(res, 403, { error: 'WebView launch is loopback-only' })
    return
  }
  const instanceId = queryInstanceId(req)
  if (instanceId === undefined) {
    writeJson(res, 400, { error: 'instanceId is required' })
    return
  }
  if (!registry.hasConnection(instanceId)) {
    writeJson(res, 409, { error: `instance "${instanceId}" is not connected` })
    return
  }
  const connection = getConnection(ctx)
  if (connection === undefined) {
    writeJson(res, 503, { error: 'DSH Connection service is not available' })
    return
  }
  const baseUrl = `http://127.0.0.1:${String(ctx.webServer.port)}`
  const authenticatedUrl = connection.authenticatedUrl(baseUrl)
  const windowName = `${options.windowPrefix}${instanceId}`
  // JSON.stringify is used for both values: instance ids are validated above,
  // while the auth URL is generated by the trusted DSH Connection service.
  const body = '<!doctype html><html><head><meta charset="utf-8"><title>DSH WebView</title></head>'
    + `<body><p>Opening DSH...</p><script>window.name=${JSON.stringify(windowName)};location.replace(${JSON.stringify(authenticatedUrl)});</script></body></html>`
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
  })
  res.end(body)
}

async function bindSession(
  ctx: Context,
  registry: WebViewInstanceRegistry,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  if (req.method !== 'POST') {
    res.writeHead(405, { allow: 'POST' })
    res.end()
    return
  }
  if (!authorizeApi(ctx, req, res)) return
  let body: unknown
  try {
    body = JSON.parse(await readBody(req))
  } catch {
    writeJson(res, 400, { error: 'request body must be valid JSON' })
    return
  }
  const record = isRecord(body) ? body : {}
  const sessionId = typeof record.sessionId === 'string' ? record.sessionId : undefined
  const instanceId = typeof record.instanceId === 'string' ? record.instanceId : undefined
  if (sessionId === undefined || instanceId === undefined) {
    writeJson(res, 400, { error: 'sessionId and instanceId are required' })
    return
  }
  try {
    writeJson(res, 200, { ok: true, ...registry.bindSession(sessionId, instanceId) })
  } catch (error: unknown) {
    writeBridgeError(res, error)
  }
}

function readInstanceStatus(
  ctx: Context,
  registry: WebViewInstanceRegistry,
  req: IncomingMessage,
  res: ServerResponse,
): void {
  if (req.method !== 'GET') {
    res.writeHead(405, { allow: 'GET' })
    res.end()
    return
  }
  if (!authorizeApi(ctx, req, res)) return
  const instanceId = queryInstanceId(req)
  if (instanceId === undefined) {
    writeJson(res, 200, { instances: registry.instances() })
    return
  }
  const status = registry.instanceStatus(instanceId)
  if (status === undefined) {
    writeJson(res, 404, { error: `instance "${instanceId}" is not connected` })
    return
  }
  writeJson(res, 200, status)
}

function authorizeApi(ctx: Context, req: IncomingMessage, res: ServerResponse): boolean {
  const connection = getConnection(ctx)
  if (connection === undefined) {
    writeJson(res, 503, { error: 'DSH Connection service is not available' })
    return false
  }
  const rejection = connection.requestRejection(req)
  if (rejection !== undefined) {
    res.writeHead(rejection)
    res.end(rejection === 401 ? 'unauthorized' : 'forbidden')
    return false
  }
  return true
}

function getConnection(ctx: Context): HostConnectionLike | undefined {
  const value = ctx.get('connection') as unknown
  if (!isRecord(value)
    || typeof value.authenticatedUrl !== 'function'
    || typeof value.requestRejection !== 'function') return undefined
  return value as unknown as HostConnectionLike
}

function queryInstanceId(req: IncomingMessage): string | undefined {
  const value = new URL(req.url ?? '/', 'http://127.0.0.1').searchParams.get('instanceId')
  return value !== null && isInstanceId(value) ? value : undefined
}

function writeJson(res: ServerResponse, status: number, value: unknown): void {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  })
  res.end(JSON.stringify(value))
}

function writeBridgeError(res: ServerResponse, error: unknown): void {
  if (error instanceof SketchupBridgeError) {
    const status = error.code === 'unknown-instance' ? 404 : error.code === 'ambiguous' ? 409 : 400
    writeJson(res, status, { error: error.message, code: error.code })
    return
  }
  writeJson(res, 500, { error: String(error) })
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let bytes = 0
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer | string) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
      bytes += buffer.length
      if (bytes > MAX_BODY_BYTES) {
        reject(new Error('request body too large'))
        req.destroy()
        return
      }
      chunks.push(buffer)
    })
    req.once('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.once('error', reject)
  })
}

/** Inject one identity prelude before the DSH app module runs. */
export function injectSurfacePrelude(
  html: string,
  options: WebViewSurfaceOptions = SKETCHUP_SURFACE_OPTIONS,
): string {
  assertSurfaceOptions(options)
  const marker = surfaceMarker(options)
  if (html.includes(marker)) return html
  const script = `<script ${marker}>${surfaceScript(options)}</script>`
  const head = html.indexOf('</head>')
  return head === -1 ? `${script}${html}` : `${html.slice(0, head)}${script}${html.slice(head)}`
}

function surfaceScript(options: WebViewSurfaceOptions): string {
  // Keep this as ordinary browser JavaScript. It intentionally uses only
  // standard Web APIs because the prelude runs before the DSH module loader.
  return `(() => {
  const prefix = ${JSON.stringify(options.windowPrefix)};
  const bindPath = ${JSON.stringify(options.bindPath)};
  const statusPath = ${JSON.stringify(options.statusPath)};
  const label = ${JSON.stringify(options.label)};
  const surfaceId = ${JSON.stringify(options.surfaceId)};
  const instanceAttribute = 'data-dsh-' + surfaceId + '-instance';
  const stripId = 'dsh-' + surfaceId + '-surface-strip';
  const instanceIdPrefix = ${JSON.stringify(options.instanceIdPrefix ?? '')};
  const name = typeof window.name === 'string' ? window.name : '';
  if (!name.startsWith(prefix)) return;
  const instanceId = name.slice(prefix.length);
  if (!${INSTANCE_ID_PATTERN.toString()}.test(instanceId)) return;
  const shortInstanceId = instanceIdPrefix !== '' && instanceId.startsWith(instanceIdPrefix)
    ? instanceId.slice(instanceIdPrefix.length, instanceIdPrefix.length + 8)
    : instanceId.slice(0, 8);

  // SketchUp 2024 embeds Chromium 112. DSH's current client runtime uses these
  // newer platform APIs, so install spec-shaped shims before its module graph
  // evaluates. They are no-ops in browsers that already implement the APIs.
  if (typeof Promise === 'function' && typeof Promise.withResolvers !== 'function') {
    Object.defineProperty(Promise, 'withResolvers', {
      configurable: true,
      writable: true,
      value: function() {
        let resolve;
        let reject;
        const promise = new this((nextResolve, nextReject) => {
          resolve = nextResolve;
          reject = nextReject;
        });
        return { promise, resolve, reject };
      },
    });
  }
  if (typeof AbortSignal === 'function' && typeof AbortController === 'function'
    && typeof AbortSignal.any !== 'function') {
    Object.defineProperty(AbortSignal, 'any', {
      configurable: true,
      writable: true,
      value: function(signals) {
        if (signals == null || typeof signals[Symbol.iterator] !== 'function') {
          throw new TypeError('AbortSignal.any expects an iterable of signals');
        }
        const controller = new AbortController();
        const listeners = [];
        let finished = false;
        const complete = signal => {
          if (finished) return;
          finished = true;
          for (const entry of listeners) entry.signal.removeEventListener('abort', entry.listener);
          controller.abort(signal.reason);
        };
        for (const signal of signals) {
          if (signal == null || typeof signal.addEventListener !== 'function') {
            throw new TypeError('AbortSignal.any received a non-signal value');
          }
          if (signal.aborted) {
            complete(signal);
            break;
          }
          const listener = () => complete(signal);
          listeners.push({ signal, listener });
          signal.addEventListener('abort', listener, { once: true });
        }
        return controller.signal;
      },
    });
  }

  // Some embedded WebViews report navigator.onLine=false because they cannot
  // probe the public internet, even though this authenticated localhost
  // surface is reachable. Connection uses that flag as a gate before it opens
  // its local Remote carrier, so advertise this surface as online and notify
  // listeners after the prelude has installed. This does not claim external
  // network reachability; it only removes a false offline state for DSH's local
  // transport.
  let needsOnlineSignal = false;
  try {
    if (window.navigator && window.navigator.onLine === false) {
      needsOnlineSignal = true;
      Object.defineProperty(window.navigator, 'onLine', {
        configurable: true,
        get: () => true,
      });
    }
  } catch { needsOnlineSignal = true; }
  if (needsOnlineSignal) {
    const announceOnline = () => window.dispatchEvent(new Event('online'));
    if (typeof window.queueMicrotask === 'function') window.queueMicrotask(announceOnline);
    else window.setTimeout(announceOnline, 0);
  }
  document.documentElement.setAttribute(instanceAttribute, instanceId);
  window.dispatchEvent(new CustomEvent('dsh-webview-surface', { detail: { instanceId, label, surfaceId } }));

  const originalFetch = window.fetch.bind(window);
  const bound = new Set();
  const pending = new Map();
  const sessionIdFrom = (value, depth = 0) => {
    if (depth > 5 || value === null || typeof value !== 'object') return null;
    if (Array.isArray(value)) {
      for (const child of value) { const found = sessionIdFrom(child, depth + 1); if (found) return found; }
      return null;
    }
    for (const [key, child] of Object.entries(value)) {
      if (key === 'sessionId' && typeof child === 'string' && child.length > 0) return child;
      const found = sessionIdFrom(child, depth + 1);
      if (found) return found;
    }
    return null;
  };
  const bodyObject = async (input, init) => {
    let text = typeof init?.body === 'string' ? init.body : null;
    if (text === null && typeof Request !== 'undefined' && input instanceof Request) {
      try { text = await input.clone().text(); } catch { text = null; }
    }
    if (text === null || text.length === 0) return null;
    try { return JSON.parse(text); } catch { return null; }
  };
  const bind = async (sessionId) => {
    if (bound.has(sessionId)) return;
    const existing = pending.get(sessionId);
    if (existing) return existing;
    const task = (async () => {
      try {
        const response = await originalFetch(bindPath, {
          method: 'POST', credentials: 'same-origin',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ sessionId, instanceId }),
        });
        if (!response.ok) return;
        bound.add(sessionId);
      } catch { /* the DSH request remains authoritative */ }
      finally { pending.delete(sessionId); }
    })();
    pending.set(sessionId, task);
    return task;
  };
  window.fetch = async (input, init) => {
    const rawUrl = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const url = new URL(rawUrl, location.href);
    const method = (init?.method || (typeof input !== 'string' && !(input instanceof URL) ? input.method : 'GET')).toUpperCase();
    const isSessionRpc = url.pathname.startsWith('/api/session/') && method === 'POST';
    const requestBody = isSessionRpc ? await bodyObject(input, init) : null;
    const knownSession = requestBody ? sessionIdFrom(requestBody) : null;
    if (knownSession) await bind(knownSession);
    const response = await originalFetch(input, init);
    if (isSessionRpc && url.pathname.endsWith('/create')) {
      try {
        const created = await response.clone().json();
        const createdSession = sessionIdFrom(created);
        if (createdSession) await bind(createdSession);
      } catch { /* retain the original response for the DSH client */ }
    }
    return response;
  };

  // Session follow/page streams can be opened before their first unary call.
  // Delay only the first Remote mux frame until its Session binding is sent;
  // unrelated WebSockets retain their native behavior.
  try {
    const socketPrototype = window.WebSocket && window.WebSocket.prototype;
    const nativeSend = socketPrototype && socketPrototype.send;
    if (socketPrototype && typeof nativeSend === 'function' && !socketPrototype.__dshSurfacePatched) {
      socketPrototype.send = function(data) {
        let sessionId = null;
        try {
          const socketUrl = new URL(this.url, location.href);
          if (socketUrl.pathname === '/api/remote.mux' && typeof data === 'string') {
            const frame = JSON.parse(data);
            if (frame && frame.type === 'open') sessionId = sessionIdFrom(frame.payload);
          }
        } catch { sessionId = null; }
        if (sessionId) {
          const socket = this;
          void bind(sessionId).then(() => nativeSend.call(socket, data), () => nativeSend.call(socket, data));
          return;
        }
        return nativeSend.call(this, data);
      };
      Object.defineProperty(socketPrototype, '__dshSurfacePatched', { value: true, configurable: false });
    }
  } catch { /* old WebViews may expose a non-extensible WebSocket prototype */ }

  const renderStrip = () => {
    if (document.getElementById(stripId)) return;
    const strip = document.createElement('div');
    strip.id = stripId;
    strip.textContent = label + ' - ' + shortInstanceId;
    strip.title = 'Bound ' + label + ' instance ' + instanceId;
    strip.style.cssText = 'position:fixed;top:8px;right:12px;z-index:2147483647;pointer-events:none;box-sizing:border-box;padding:5px 9px;border:1px solid rgba(127,127,127,.35);border-radius:6px;background:rgba(20,24,30,.88);color:#f4f6f8;font:12px/16px system-ui,sans-serif;letter-spacing:0;box-shadow:0 2px 8px rgba(0,0,0,.22)';
    document.body.appendChild(strip);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', renderStrip, { once: true });
  else renderStrip();

  const refreshStatus = async () => {
    try {
      const response = await originalFetch(statusPath + '?instanceId=' + encodeURIComponent(instanceId), { credentials: 'same-origin' });
      const status = await response.json();
      const strip = document.getElementById(stripId);
      if (strip && status && status.connected !== false) strip.textContent = label + ' - ' + shortInstanceId;
      if (strip && status && status.connected === false) strip.textContent = label + ' - disconnected';
    } catch { /* the DSH app remains usable while the status poll retries */ }
  };
  void refreshStatus();
  if (typeof window.setInterval === 'function') window.setInterval(refreshStatus, 5000);
})();`
}

function surfaceMarker(options: WebViewSurfaceOptions): string {
  return `data-dsh-${options.surfaceId}-surface`
}

function assertSurfaceOptions(options: WebViewSurfaceOptions): void {
  for (const name of ['launchPath', 'bindPath', 'statusPath', 'windowPrefix', 'surfaceId', 'label']) {
    const value = options[name as keyof WebViewSurfaceOptions]
    if (typeof value !== 'string' || value.length === 0) {
      throw new Error(`WebView surface ${name} must be a non-empty string`)
    }
  }
  if (!SURFACE_ID_PATTERN.test(options.surfaceId)) {
    throw new Error('WebView surface surfaceId must be lowercase letters, digits, or hyphens')
  }
  if (options.instanceIdPrefix !== undefined
    && (typeof options.instanceIdPrefix !== 'string' || options.instanceIdPrefix.length === 0)) {
    throw new Error('WebView surface instanceIdPrefix must be a non-empty string when provided')
  }
  for (const name of ['launchPath', 'bindPath', 'statusPath'] as const) {
    const value = options[name]
    if (!value.startsWith('/') || value.includes('?') || value.includes('#')) {
      throw new Error(`WebView surface ${name} must be an absolute pathname`)
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Exported for focused tests and future native-host adapters. */
export const SKETCHUP_SURFACE_PATHS = {
  chat: SKETCHUP_CHAT_PATH,
  bind: SKETCHUP_SESSION_BIND_PATH,
  status: SKETCHUP_INSTANCE_STATUS_PATH,
} as const

/** Keep the identity validator available to package-level tests. */
export const SKETCHUP_SURFACE_INSTANCE_PATTERN = INSTANCE_ID_PATTERN
