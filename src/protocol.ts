/**
 * Wire contract for the DSH <-> SketchUp Ruby bridge.
 *
 * Frames are one JSON object per WebSocket message. The SketchUp side is a
 * small Ruby client, so this module deliberately has no runtime dependencies;
 * the Ruby implementation mirrors these fields rather than importing JS.
 */

/** WebSocket path registered by the Host plugin. */
export const SKETCHUP_BRIDGE_PATH = '/ext/sketchup'

/**
 * Origin emitted by the native SketchUp client. It is a local CSRF boundary,
 * analogous to the chrome-extension:// origin used by the browser bridge; it
 * is not intended to be a cryptographic secret.
 */
export const SKETCHUP_BRIDGE_ORIGIN = 'sketchup://dsh-bridge'

/** Human-readable discovery endpoint registered by the Host plugin. */
export const SKETCHUP_CONFIG_PATH = '/ext/sketchup-config'

/** Launch endpoint for the reusable DSH WebView surface. */
export const SKETCHUP_CHAT_PATH = '/ext/sketchup-chat'

/** Authenticated RPC used by the WebView to bind its Agent Session to an instance. */
export const SKETCHUP_SESSION_BIND_PATH = '/ext/sketchup-session-bind'

/** Read-only status endpoint used by the WebView identity strip. */
export const SKETCHUP_INSTANCE_STATUS_PATH = '/ext/sketchup-instance-status'

/** Prefix stored in window.name while a native WebView surface is open. */
export const SKETCHUP_SURFACE_WINDOW_PREFIX = 'dsh-sketchup:'

/** Current wire protocol revision. */
export const PROTOCOL_VERSION = 1 as const

/** Fresh sockets must complete the hello handshake promptly. */
export const HELLO_TIMEOUT_MS = 5_000

/** Server keepalive cadence. */
export const PING_INTERVAL_MS = 30_000

/** Default event history retained by the Ruby client and Host. */
export const DEFAULT_HISTORY_EVENTS = 200

/** Maximum event payload accepted by the Host before it is marked truncated. */
export const DEFAULT_EVENT_PAYLOAD_BYTES = 64 * 1024

/** Default per-tool-call budget. */
export const DEFAULT_TOOL_TIMEOUT_MS = 90_000

/** Instance ids are opaque, bounded, and safe to echo into JSON/DOM attributes. */
export const INSTANCE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/

/** JSON values carried on the wire. */
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }

/** Capabilities advertised by the SketchUp Ruby client. */
export interface SketchupCaps {
  client: 'sketchup-ruby'
  protocol: typeof PROTOCOL_VERSION
  /** Stable for the lifetime of one SketchUp process/bridge manager. */
  instanceId?: string
  sketchupVersion?: string
  rubyVersion?: string
  features: string[]
}

/** Capabilities advertised by the DSH Host. */
export interface HostCaps {
  protocol: typeof PROTOCOL_VERSION
  historyEvents: number
  eventPayloadBytes: number
  pluginWriteEnabled: boolean
  pluginLoadEnabled: boolean
}

/** Structured error returned for a tool call. */
export interface ToolError {
  code: string
  message: string
}

/** Frames sent by SketchUp to the Host. */
export type ClientFrame =
  | {
      t: 'hello'
      caps: SketchupCaps
    }
  | {
      t: 'tool.result'
      id: string
      ok: true
      result: JsonValue
    }
  | {
      t: 'tool.result'
      id: string
      ok: false
      error: ToolError
    }
  | {
      t: 'event'
      seq: number
      at: number
      name: string
      payload: JsonValue
    }
  | { t: 'pong' }

/** Frames sent by the Host to SketchUp. */
export type ServerFrame =
  | { t: 'hello.ok'; caps: HostCaps }
  | {
      t: 'tool.call'
      id: string
      name: string
      args: Record<string, JsonValue>
      expiresAt: number
    }
  | { t: 'tool.cancel'; id: string }
  | { t: 'ping' }
  | { t: 'error'; code: string; message: string }

/** Any parsed wire frame. */
export type BridgeFrame = ClientFrame | ServerFrame

/** Check whether a value is a plain JSON object. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Check the instance identity carried by a SketchUp hello. */
export function isInstanceId(value: unknown): value is string {
  return typeof value === 'string' && INSTANCE_ID_PATTERN.test(value)
}

/** Check the small capability object sent by SketchUp. */
function isSketchupCaps(value: unknown): value is SketchupCaps {
  if (!isRecord(value)) return false
  return value.client === 'sketchup-ruby'
    && value.protocol === PROTOCOL_VERSION
    && (value.instanceId === undefined || isInstanceId(value.instanceId))
    && Array.isArray(value.features)
    && value.features.every((feature) => typeof feature === 'string')
    && (value.sketchupVersion === undefined || typeof value.sketchupVersion === 'string')
    && (value.rubyVersion === undefined || typeof value.rubyVersion === 'string')
}

/** Check the Host capability object. */
function isHostCaps(value: unknown): value is HostCaps {
  if (!isRecord(value)) return false
  return value.protocol === PROTOCOL_VERSION
    && typeof value.historyEvents === 'number'
    && Number.isInteger(value.historyEvents)
    && value.historyEvents > 0
    && typeof value.eventPayloadBytes === 'number'
    && Number.isInteger(value.eventPayloadBytes)
    && value.eventPayloadBytes > 0
    && typeof value.pluginWriteEnabled === 'boolean'
    && typeof value.pluginLoadEnabled === 'boolean'
}

/** Check a JSON-compatible error object. */
function isToolError(value: unknown): value is ToolError {
  return isRecord(value) && typeof value.code === 'string' && typeof value.message === 'string'
}

/** Parse and validate one WebSocket message. */
export function parseBridgeFrame(text: string): BridgeFrame | undefined {
  let value: unknown
  try {
    value = JSON.parse(text)
  } catch {
    return undefined
  }
  if (!isRecord(value) || typeof value.t !== 'string') return undefined

  switch (value.t) {
    case 'hello':
      return isSketchupCaps(value.caps)
        ? { t: 'hello', caps: value.caps }
        : undefined
    case 'tool.result':
      if (typeof value.id !== 'string') return undefined
      if (value.ok === true && 'result' in value) {
        return { t: 'tool.result', id: value.id, ok: true, result: value.result as JsonValue }
      }
      return value.ok === false && isToolError(value.error)
        ? { t: 'tool.result', id: value.id, ok: false, error: value.error }
        : undefined
    case 'event':
      return typeof value.seq === 'number'
        && Number.isInteger(value.seq)
        && value.seq >= 0
        && typeof value.at === 'number'
        && Number.isFinite(value.at)
        && typeof value.name === 'string'
        && value.name.length > 0
        && 'payload' in value
        ? {
            t: 'event',
            seq: value.seq,
            at: value.at,
            name: value.name,
            payload: value.payload as JsonValue,
          }
        : undefined
    case 'pong':
      return { t: 'pong' }
    case 'hello.ok':
      return isHostCaps(value.caps) ? { t: 'hello.ok', caps: value.caps } : undefined
    case 'tool.call':
      return typeof value.id === 'string'
        && typeof value.name === 'string'
        && isRecord(value.args)
        && typeof value.expiresAt === 'number'
        && Number.isFinite(value.expiresAt)
        && value.expiresAt > 0
        ? {
            t: 'tool.call',
            id: value.id,
            name: value.name,
            args: value.args as Record<string, JsonValue>,
            expiresAt: value.expiresAt,
          }
        : undefined
    case 'tool.cancel':
      return typeof value.id === 'string' ? { t: 'tool.cancel', id: value.id } : undefined
    case 'ping':
      return { t: 'ping' }
    case 'error':
      return typeof value.code === 'string' && typeof value.message === 'string'
        ? { t: 'error', code: value.code, message: value.message }
        : undefined
    default:
      return undefined
  }
}

/** Narrow a parsed frame to a client-originated frame. */
export function isClientFrame(frame: BridgeFrame): frame is ClientFrame {
  return frame.t === 'hello'
    || frame.t === 'tool.result'
    || frame.t === 'event'
    || frame.t === 'pong'
}

/** Narrow a parsed frame to a Host-originated frame. */
export function isServerFrame(frame: BridgeFrame): frame is ServerFrame {
  return frame.t === 'hello.ok'
    || frame.t === 'tool.call'
    || frame.t === 'tool.cancel'
    || frame.t === 'ping'
    || frame.t === 'error'
}
