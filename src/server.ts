/**
 * Host-side WebSocket carrier for local SketchUp Ruby clients.
 *
 * The carrier owns no SketchUp state. It verifies the loopback/Origin boundary,
 * keeps one live connection per declared SketchUp process, forwards bounded tool
 * calls, and retains a small per-instance audit buffer. The Ruby client remains
 * the only code allowed to touch the SketchUp API and it does so on SketchUp's
 * UI thread.
 */

import { randomUUID } from 'node:crypto'
import type { IncomingMessage } from 'node:http'
import type { Duplex } from 'node:stream'
import { WebSocket, WebSocketServer, type RawData } from 'ws'
import {
  DEFAULT_EVENT_PAYLOAD_BYTES,
  HELLO_TIMEOUT_MS,
  INSTANCE_ID_PATTERN,
  PING_INTERVAL_MS,
  SKETCHUP_BRIDGE_ORIGIN,
  type BridgeFrame,
  type ClientFrame,
  type JsonValue,
  type ServerFrame,
  type SketchupCaps,
  isInstanceId,
  parseBridgeFrame,
} from './protocol.ts'

/** Stable errors exposed by a failed model-facing SketchUp tool. */
export type ToolErrorCode =
  | 'bridge-closed'
  | 'timeout'
  | 'action-failed'
  | 'not-enabled'
  | 'internal'
  | 'bad-args'
  | 'ambiguous'
  | 'unknown-instance'

/** Error class the DSH tool registry turns into a failed tool result. */
export class SketchupBridgeError extends Error {
  constructor(
    readonly code: ToolErrorCode,
    message: string,
  ) {
    super(message)
    this.name = 'SketchupBridgeError'
  }
}

/** One event retained by the Host-side live audit buffer. */
export interface SketchupHistoryEvent {
  /** Instance that produced the event; required for multi-instance audits. */
  instanceId: string
  seq: number
  at: number
  name: string
  payload: JsonValue | { truncated: true; bytes: number }
}

/** A bounded read-only description of one connected SketchUp process. */
export interface SketchupInstanceStatus {
  instanceId: string
  connected: true
  connectedAt: number
  remoteAddress?: string
  sketchupVersion?: string
  rubyVersion?: string
  features: string[]
  historyEvents: number
  lastEventAt?: number
}

/** Dependencies and safety bounds for the carrier. */
export interface SketchupBridgeServerDeps {
  toolTimeoutMs: number
  maxHistoryEvents: number
  maxEventPayloadBytes?: number
  pluginWriteEnabled: boolean
  pluginLoadEnabled: boolean
  remoteAddressOverride?: string
  helloTimeoutMs?: number
  pingIntervalMs?: number
}

interface PendingTool {
  resolve: (value: unknown) => void
  reject: (error: SketchupBridgeError) => void
  timer: NodeJS.Timeout
  cleanup: () => void
  connection: ReadyConnection
}

interface ReadyConnection {
  ws: WebSocket
  remoteAddress: string | undefined
  ping: NodeJS.Timeout
  caps: SketchupCaps & { instanceId: string }
  connectedAt: number
}

/** Loopback literals accepted by the Host safety fence. */
export function isLoopbackAddress(address: string | undefined): boolean {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1'
}

/** Decode the delivery shapes emitted by the `ws` package. */
export function messageToText(data: RawData): string {
  if (Array.isArray(data)) return Buffer.concat(data).toString('utf8')
  if (Buffer.isBuffer(data)) return data.toString('utf8')
  return Buffer.from(data).toString('utf8')
}

function sendFrame(ws: WebSocket, frame: ServerFrame): void {
  if (ws.readyState !== WebSocket.OPEN) return
  ws.send(JSON.stringify(frame))
}

/** Validate a Session id before it becomes a long-lived routing-map key. */
function isSessionId(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 256
}

/**
 * Host registry for every connected SketchUp process.
 *
 * A connection is selected explicitly when the caller supplies an instance id,
 * by the caller's bound Agent Session when available, or implicitly only when
 * exactly one instance is connected. The last socket to connect is never a
 * routing policy.
 */
export class SketchupBridgeServer {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 8 * 1024 * 1024 })
  private readonly pendingTools = new Map<string, PendingTool>()
  private readonly connections = new Map<string, ReadyConnection>()
  private readonly histories = new Map<string, SketchupHistoryEvent[]>()
  private readonly sessionBindings = new Map<string, string>()
  private closed = false

  constructor(private readonly deps: SketchupBridgeServerDeps) {}

  /** Accept one HTTP upgrade after the webserver has selected our route. */
  handleUpgrade(req: IncomingMessage, socket: Duplex, head: Buffer): void {
    if (this.closed) {
      socket.destroy()
      return
    }
    const remoteAddress = this.deps.remoteAddressOverride ?? req.socket.remoteAddress
    const origin = req.headers.origin
    // SketchUp is a native local client, so it has no browser extension
    // identity to carry. The loopback fence plus a dedicated non-web Origin
    // gives us the same zero-config CSRF boundary as the browser bridge.
    if (!isLoopbackAddress(remoteAddress) || origin !== SKETCHUP_BRIDGE_ORIGIN) {
      socket.destroy()
      return
    }
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.attach(ws, remoteAddress)
    })
  }

  /** Whether at least one SketchUp client has completed the hello handshake. */
  hasConnection(instanceId?: string): boolean {
    return instanceId === undefined ? this.connections.size > 0 : this.connections.has(instanceId)
  }

  /** Return a stable sorted view of every connected SketchUp process. */
  instances(): SketchupInstanceStatus[] {
    return [...this.connections.values()]
      .map(connection => this.toInstanceStatus(connection))
      .sort((left, right) => left.connectedAt - right.connectedAt || left.instanceId.localeCompare(right.instanceId))
  }

  /** Read one connected process description, or undefined when it is gone. */
  instanceStatus(instanceId: string): SketchupInstanceStatus | undefined {
    const connection = this.connections.get(instanceId)
    return connection === undefined ? undefined : this.toInstanceStatus(connection)
  }

  /** Small status object used by `sketchup_status`. */
  status(): {
    connected: boolean
    instanceCount: number
    instances: SketchupInstanceStatus[]
    historyEvents: number
    lastEventAt?: number
    pluginWriteEnabled: boolean
    pluginLoadEnabled: boolean
  } {
    const all = this.instances()
    const lastEventAt = all.reduce<number | undefined>((latest, item) =>
      item.lastEventAt === undefined ? latest : latest === undefined ? item.lastEventAt : Math.max(latest, item.lastEventAt), undefined)
    return {
      connected: all.length > 0,
      instanceCount: all.length,
      instances: all,
      historyEvents: all.reduce((total, item) => total + item.historyEvents, 0),
      ...(lastEventAt === undefined ? {} : { lastEventAt }),
      pluginWriteEnabled: this.deps.pluginWriteEnabled,
      pluginLoadEnabled: this.deps.pluginLoadEnabled,
    }
  }

  /** Bind one DSH Agent Session to one currently connected SketchUp instance. */
  bindSession(sessionId: string, instanceId: string): { sessionId: string; instanceId: string } {
    if (!isSessionId(sessionId)) {
      throw new SketchupBridgeError('bad-args', 'sessionId must be a non-empty string of at most 256 characters')
    }
    if (!isInstanceId(instanceId)) {
      throw new SketchupBridgeError('bad-args', 'instanceId has an invalid format')
    }
    if (!this.connections.has(instanceId)) {
      throw new SketchupBridgeError('unknown-instance', `SketchUp instance "${instanceId}" is not connected`)
    }
    this.sessionBindings.set(sessionId, instanceId)
    return { sessionId, instanceId }
  }

  /** Remove one Session binding; idempotent for page teardown and rebinding. */
  unbindSession(sessionId: string): void {
    this.sessionBindings.delete(sessionId)
  }

  /** Resolve and return the most recent bounded events for one target. */
  history(
    limit = this.deps.maxHistoryEvents,
    instanceId?: string,
    sessionId?: string,
  ): SketchupHistoryEvent[] {
    const target = this.resolveTarget(instanceId, sessionId, 'history')
    if (target === undefined) {
      // This branch is reachable only when there are no connections. Returning
      // an empty buffer keeps a read-only history query deterministic.
      return []
    }
    const bounded = Math.max(1, Math.min(this.deps.maxHistoryEvents, Math.floor(limit)))
    return (this.histories.get(target) ?? []).slice(-bounded).map(event => ({
      ...event,
      payload: cloneJson(event.payload),
    }))
  }

  /** Clear only the selected Host-side live buffer; Ruby history is separate. */
  clearHistory(instanceId?: string, sessionId?: string): void {
    const target = this.resolveTarget(instanceId, sessionId, 'clear history')
    if (target !== undefined) this.histories.get(target)?.splice(0)
  }

  /**
   * Send one model-facing action to a selected SketchUp instance and await its
   * result. Cancellation and timeout also send `tool.cancel` so a queued action
   * is withdrawn before it reaches the SketchUp UI thread.
   *
   * @param sessionId - Agent Session identity used for implicit binding.
   * @param instanceId - explicit target override; never inferred from recency.
   */
  requestTool(
    name: string,
    args: Record<string, JsonValue>,
    signal: AbortSignal,
    timeoutMs = this.deps.toolTimeoutMs,
    sessionId?: string,
    instanceId?: string,
  ): Promise<unknown> {
    const targetId = this.resolveTarget(instanceId, sessionId, `tool "${name}"`)
    if (targetId === undefined) {
      throw new SketchupBridgeError('bridge-closed', 'no SketchUp client is connected')
    }
    const connection = this.connections.get(targetId)
    if (connection === undefined) {
      throw new SketchupBridgeError('unknown-instance', `SketchUp instance "${targetId}" is not connected`)
    }
    if (signal.aborted) {
      throw new SketchupBridgeError('bridge-closed', 'SketchUp tool call was cancelled before dispatch')
    }

    const id = randomUUID()
    const expiresAt = Date.now() + timeoutMs
    return new Promise<unknown>((resolve, reject) => {
      let timer: NodeJS.Timeout
      const cleanup = (): void => {
        clearTimeout(timer)
        signal.removeEventListener('abort', onAbort)
      }
      const settle = (error?: SketchupBridgeError, value?: unknown): void => {
        if (!this.pendingTools.has(id)) return
        cleanup()
        this.pendingTools.delete(id)
        if (error === undefined) resolve(value)
        else reject(error)
      }
      const cancel = (error: SketchupBridgeError): void => {
        sendFrame(connection.ws, { t: 'tool.cancel', id })
        settle(error)
      }
      const onAbort = (): void => {
        cancel(new SketchupBridgeError('bridge-closed', 'SketchUp tool call was cancelled'))
      }

      timer = setTimeout(() => {
        cancel(new SketchupBridgeError('timeout', `SketchUp action "${name}" timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pendingTools.set(id, { resolve, reject, timer, cleanup, connection })
      signal.addEventListener('abort', onAbort, { once: true })
      if (signal.aborted) onAbort()
      if (!this.pendingTools.has(id)) return

      try {
        connection.ws.send(JSON.stringify({ t: 'tool.call', id, name, args, expiresAt } satisfies ServerFrame), (error) => {
          if (error != null) {
            settle(new SketchupBridgeError('bridge-closed', `bridge socket failed before delivery: ${error.message}`))
          }
        })
      } catch (error: unknown) {
        settle(new SketchupBridgeError('bridge-closed', `bridge socket failed before delivery: ${String(error)}`))
      }
    })
  }

  /** Dispose the acceptor, sockets, timers, and pending tool calls. */
  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    for (const connection of [...this.connections.values()]) this.dropConnection(connection, 'closed')
    for (const socket of this.wss.clients) socket.terminate()
    await new Promise<void>((resolve) => {
      this.wss.close(() => resolve())
    })
  }

  private attach(ws: WebSocket, remoteAddress: string | undefined): void {
    let helloTimer: NodeJS.Timeout | undefined = setTimeout(() => {
      ws.close(4001, 'hello timeout')
    }, this.deps.helloTimeoutMs ?? HELLO_TIMEOUT_MS)
    let connection: ReadyConnection | undefined

    const onMessage = (data: RawData): void => {
      const frame = parseBridgeFrame(messageToText(data))
      if (frame === undefined) {
        ws.close(1008, 'unparseable frame')
        return
      }
      if (helloTimer !== undefined) {
        if (frame.t !== 'hello') {
          ws.close(1008, 'hello first')
          return
        }
        clearTimeout(helloTimer)
        helloTimer = undefined
        connection = this.promote(ws, remoteAddress, frame.caps)
        return
      }
      if (connection !== undefined) this.handleReadyFrame(connection, frame)
    }

    const onClose = (): void => {
      if (helloTimer !== undefined) clearTimeout(helloTimer)
      if (connection !== undefined && this.connections.get(connection.caps.instanceId) === connection) {
        this.dropConnection(connection, 'closed')
      }
    }
    ws.on('message', onMessage)
    ws.once('close', onClose)
    ws.once('error', onClose)
  }

  private promote(ws: WebSocket, remoteAddress: string | undefined, caps: SketchupCaps): ReadyConnection {
    // Older bridge extensions did not advertise an identity. Give those
    // sockets an ephemeral compatibility id instead of rejecting the whole
    // connection; updated Ruby clients always provide a process-stable id.
    const instanceId = isInstanceId(caps.instanceId) ? caps.instanceId : `legacy-${randomUUID()}`
    const normalizedCaps: SketchupCaps & { instanceId: string } = {
      ...caps,
      instanceId,
      features: [...caps.features],
    }
    const existing = this.connections.get(instanceId)
    if (existing !== undefined) this.dropConnection(existing, 'replaced')
    const ping = setInterval(() => sendFrame(ws, { t: 'ping' }), this.deps.pingIntervalMs ?? PING_INTERVAL_MS)
    const connection: ReadyConnection = {
      ws,
      remoteAddress,
      ping,
      caps: normalizedCaps,
      connectedAt: Date.now(),
    }
    this.connections.set(instanceId, connection)
    if (!this.histories.has(instanceId)) this.histories.set(instanceId, [])
    sendFrame(ws, {
      t: 'hello.ok',
      caps: {
        protocol: 1,
        historyEvents: this.deps.maxHistoryEvents,
        eventPayloadBytes: this.deps.maxEventPayloadBytes ?? DEFAULT_EVENT_PAYLOAD_BYTES,
        pluginWriteEnabled: this.deps.pluginWriteEnabled,
        pluginLoadEnabled: this.deps.pluginLoadEnabled,
      },
    })
    return connection
  }

  private handleReadyFrame(connection: ReadyConnection, frame: BridgeFrame): void {
    if (this.connections.get(connection.caps.instanceId) !== connection) return
    switch (frame.t) {
      case 'tool.result':
        if (frame.ok) this.settleTool(frame.id, undefined, frame.result, connection)
        else this.settleTool(frame.id, new SketchupBridgeError(toolErrorCode(frame.error.code), frame.error.message), undefined, connection)
        break
      case 'event':
        this.recordEvent(connection, frame)
        break
      case 'pong':
      case 'hello':
      case 'hello.ok':
      case 'tool.call':
      case 'tool.cancel':
      case 'ping':
      case 'error':
        // These are either client protocol violations or server-only frames.
        break
    }
  }

  private settleTool(
    id: string,
    error?: SketchupBridgeError,
    value?: unknown,
    connection?: ReadyConnection,
  ): void {
    const pending = this.pendingTools.get(id)
    if (pending === undefined || (connection !== undefined && pending.connection !== connection)) return
    pending.cleanup()
    this.pendingTools.delete(id)
    if (error === undefined) pending.resolve(value)
    else pending.reject(error)
  }

  private recordEvent(connection: ReadyConnection, frame: Extract<ClientFrame, { t: 'event' }>): void {
    const maxBytes = this.deps.maxEventPayloadBytes ?? DEFAULT_EVENT_PAYLOAD_BYTES
    let payload: SketchupHistoryEvent['payload'] = frame.payload
    try {
      const bytes = Buffer.byteLength(JSON.stringify(frame.payload), 'utf8')
      if (bytes > maxBytes) payload = { truncated: true, bytes }
    } catch {
      payload = { truncated: true, bytes: -1 }
    }
    const events = this.histories.get(connection.caps.instanceId) ?? []
    events.push({
      instanceId: connection.caps.instanceId,
      seq: frame.seq,
      at: frame.at,
      name: frame.name,
      payload,
    })
    while (events.length > this.deps.maxHistoryEvents) events.shift()
    this.histories.set(connection.caps.instanceId, events)
  }

  private dropConnection(connection: ReadyConnection, reason: 'closed' | 'replaced'): void {
    if (this.connections.get(connection.caps.instanceId) !== connection) return
    this.connections.delete(connection.caps.instanceId)
    clearInterval(connection.ping)
    for (const [id, pending] of this.pendingTools) {
      if (pending.connection !== connection) continue
      pending.cleanup()
      this.pendingTools.delete(id)
      pending.reject(new SketchupBridgeError('bridge-closed', reason === 'replaced'
        ? 'the SketchUp connection for this instance was replaced'
        : 'the SketchUp connection for this instance was closed'))
    }
    if (connection.ws.readyState === WebSocket.OPEN || connection.ws.readyState === WebSocket.CONNECTING) {
      connection.ws.close(reason === 'replaced' ? 4000 : 4002, reason)
    }
  }

  private resolveTarget(
    explicitInstanceId: string | undefined,
    sessionId: string | undefined,
    operation: string,
  ): string | undefined {
    if (explicitInstanceId !== undefined) {
      if (!isInstanceId(explicitInstanceId)) {
        throw new SketchupBridgeError('bad-args', 'instanceId has an invalid format')
      }
      if (!this.connections.has(explicitInstanceId)) {
        throw new SketchupBridgeError('unknown-instance', `SketchUp instance "${explicitInstanceId}" is not connected`)
      }
      return explicitInstanceId
    }
    if (sessionId !== undefined) {
      const bound = this.sessionBindings.get(sessionId)
      if (bound !== undefined) {
        if (this.connections.has(bound)) return bound
        // Preserve a stale binding and fail closed. A session bound to instance A
        // must never silently issue a model edit to a different sole instance B.
        throw new SketchupBridgeError(
          'unknown-instance',
          `SketchUp instance "${bound}" previously bound to this session is not connected`,
        )
      }
    }
    if (this.connections.size === 0) return undefined
    if (this.connections.size === 1) return this.connections.keys().next().value as string
    throw new SketchupBridgeError(
      'ambiguous',
      `${operation} needs an explicit instanceId because ${this.connections.size} SketchUp instances are connected`,
    )
  }

  private toInstanceStatus(connection: ReadyConnection): SketchupInstanceStatus {
    const events = this.histories.get(connection.caps.instanceId) ?? []
    const last = events.at(-1)
    return {
      instanceId: connection.caps.instanceId,
      connected: true,
      connectedAt: connection.connectedAt,
      ...(connection.remoteAddress === undefined ? {} : { remoteAddress: connection.remoteAddress }),
      ...(connection.caps.sketchupVersion === undefined ? {} : { sketchupVersion: connection.caps.sketchupVersion }),
      ...(connection.caps.rubyVersion === undefined ? {} : { rubyVersion: connection.caps.rubyVersion }),
      features: [...connection.caps.features],
      historyEvents: events.length,
      ...(last === undefined ? {} : { lastEventAt: last.at }),
    }
  }
}

function cloneJson(value: JsonValue | { truncated: true; bytes: number }): JsonValue | { truncated: true; bytes: number } {
  if (typeof value !== 'object' || value === null) return value
  if (Array.isArray(value)) return value.map(item => cloneJson(item as JsonValue)) as JsonValue[]
  // An event may itself contain a legitimate `truncated` field; copy every key.
  const out: Record<string, JsonValue> = Object.create(null)
  for (const [key, child] of Object.entries(value)) out[key] = cloneJson(child as JsonValue) as JsonValue
  return out
}

function toolErrorCode(code: string): ToolErrorCode {
  switch (code) {
    case 'timeout':
    case 'action-failed':
    case 'not-enabled':
    case 'internal':
    case 'bridge-closed':
    case 'bad-args':
    case 'ambiguous':
    case 'unknown-instance':
      return code
    default:
      return 'internal'
  }
}

/** Keep the identity validator visible to consumers that inspect the carrier. */
export { INSTANCE_ID_PATTERN }
