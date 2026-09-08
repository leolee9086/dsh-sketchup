/**
 * `@yuxianglin/dsh-bridge-sketchup`: local DSH integration for SketchUp 2024.
 *
 * The Host half owns the loopback/Origin-gated WebSocket carrier and model-facing
 * tools. A separate Ruby extension in SketchUp owns all SketchUp API calls.
 * Keeping that split means DSH can be upgraded independently and the Host
 * never tries to call SketchUp objects from a Node process.
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type { WebRoute, WebUpgradeRoute } from '@deepseek-ai/dsh-host-webserver'
import {
  DEFAULT_EVENT_PAYLOAD_BYTES,
  DEFAULT_HISTORY_EVENTS,
  DEFAULT_TOOL_TIMEOUT_MS,
  SKETCHUP_BRIDGE_ORIGIN,
  SKETCHUP_BRIDGE_PATH,
  SKETCHUP_CHAT_PATH,
  SKETCHUP_CONFIG_PATH,
  SKETCHUP_INSTANCE_STATUS_PATH,
  SKETCHUP_SESSION_BIND_PATH,
} from './protocol.ts'
import { isLoopbackAddress, SketchupBridgeServer } from './server.ts'
import {
  registerSketchupSurface,
  registerWebViewSurface,
  SKETCHUP_SURFACE_OPTIONS,
} from './surface.ts'
import { registerSketchupTools } from './tools.ts'

export { registerSketchupSurface, registerWebViewSurface, SKETCHUP_SURFACE_OPTIONS }
export type { WebViewInstanceRegistry, WebViewSurfaceOptions } from './surface.ts'

/** Loader-visible plugin name. */
export const name = 'bridge-sketchup'

/** Hard Host dependencies; the Ruby client is outside Cordis. */
export const inject = ['webServer', 'tools']

/** Deployment-level configuration. */
export interface Config {
  toolTimeoutMs?: number
  maxHistoryEvents?: number
  maxEventPayloadBytes?: number
  maxResultChars?: number
  allowPluginWrite?: boolean
  allowPluginLoad?: boolean
}

export const Config: z<Config> = z.object({
  toolTimeoutMs: z.number().step(1).min(1).default(DEFAULT_TOOL_TIMEOUT_MS),
  maxHistoryEvents: z.number().step(1).min(1).default(DEFAULT_HISTORY_EVENTS),
  maxEventPayloadBytes: z.number().step(1).min(1).default(DEFAULT_EVENT_PAYLOAD_BYTES),
  maxResultChars: z.number().step(1).min(1).default(120_000),
  allowPluginWrite: z.boolean().default(false),
  allowPluginLoad: z.boolean().default(false),
})

type ResolvedConfig = Required<Config>

/** Validate positive integer budgets at direct-call and Loader boundaries. */
export function assertPositiveInteger(name: string, value: number): void {
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`bridge-sketchup: ${name} must be a positive integer`)
  }
}

/** Apply defaults and reject unsafe/non-integral bounds. */
export function resolveConfig(config: Config): ResolvedConfig {
  const resolved: ResolvedConfig = {
    toolTimeoutMs: config.toolTimeoutMs ?? DEFAULT_TOOL_TIMEOUT_MS,
    maxHistoryEvents: config.maxHistoryEvents ?? DEFAULT_HISTORY_EVENTS,
    maxEventPayloadBytes: config.maxEventPayloadBytes ?? DEFAULT_EVENT_PAYLOAD_BYTES,
    maxResultChars: config.maxResultChars ?? 120_000,
    allowPluginWrite: config.allowPluginWrite ?? false,
    allowPluginLoad: config.allowPluginLoad ?? false,
  }
  assertPositiveInteger('toolTimeoutMs', resolved.toolTimeoutMs)
  assertPositiveInteger('maxHistoryEvents', resolved.maxHistoryEvents)
  assertPositiveInteger('maxEventPayloadBytes', resolved.maxEventPayloadBytes)
  assertPositiveInteger('maxResultChars', resolved.maxResultChars)
  return resolved
}

/**
 * Mount the route and tools. Nothing listens until this package appears in a
 * profile bundle, so installing the package alone is harmless.
 */
export async function apply(ctx: Context, config: Config): Promise<void> {
  const resolved = resolveConfig(config)
  const server = new SketchupBridgeServer({
    toolTimeoutMs: resolved.toolTimeoutMs,
    maxHistoryEvents: resolved.maxHistoryEvents,
    maxEventPayloadBytes: resolved.maxEventPayloadBytes,
    pluginWriteEnabled: resolved.allowPluginWrite,
    pluginLoadEnabled: resolved.allowPluginLoad,
  })

  const upgrade: WebUpgradeRoute = {
    path: SKETCHUP_BRIDGE_PATH,
    handler: (req, socket, head) => { server.handleUpgrade(req, socket, head) },
  }
  ctx.effect(() => ctx.webServer.registerUpgrade(upgrade), 'bridge-sketchup: WebSocket route')
  ctx.effect(() => () => server.close(), 'bridge-sketchup: server')

  const configRoute: WebRoute = {
    kind: 'exact',
    path: SKETCHUP_CONFIG_PATH,
    handler: (req, res) => {
      if (!isLoopbackAddress(req.socket.remoteAddress)) {
        res.writeHead(403)
        res.end('forbidden')
        return
      }
      res.writeHead(200, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      })
      res.end(JSON.stringify({
        wsUrl: `ws://127.0.0.1:${ctx.webServer.port}${SKETCHUP_BRIDGE_PATH}`,
        origin: SKETCHUP_BRIDGE_ORIGIN,
        protocol: 1,
        chatPath: SKETCHUP_CHAT_PATH,
        sessionBindPath: SKETCHUP_SESSION_BIND_PATH,
        instanceStatusPath: SKETCHUP_INSTANCE_STATUS_PATH,
        instances: server.instances(),
      }))
    },
  }
  ctx.effect(() => ctx.webServer.register(configRoute), 'bridge-sketchup: config route')
  ctx.effect(() => registerSketchupSurface(ctx, server), 'bridge-sketchup: WebView surface')

  ctx.effect(() => {
    const disposers = registerSketchupTools(ctx, server, {
      toolTimeoutMs: resolved.toolTimeoutMs,
      maxResultChars: resolved.maxResultChars,
    })
    return () => { for (const dispose of disposers.values()) dispose() }
  }, 'bridge-sketchup: model tools')

  const systemPrompt = ctx.get('systemPrompt')
  if (systemPrompt !== undefined) {
    ctx.effect(() => systemPrompt.section({
      name: 'tool:bridge-sketchup',
      order: 108,
      text: 'A local SketchUp bridge may be connected. Use sketchup_status first when the target is unclear; it lists connected instanceId values. Use the instanceId argument when multiple instances are connected. Then use sketchup_snapshot, sketchup_selection, '
        + 'sketchup_history, and sketchup_query to inspect the model; use sketchup_execute only with explicit '
        + 'structured operations. Native UI history names are not always exposed by SketchUp observers. Plugin writing '
        + 'and loading require confirm=true and an enabled Host configuration.',
    }), 'bridge-sketchup: system prompt')
  }

  ctx.logger.info(`SketchUp bridge: listening on ${SKETCHUP_BRIDGE_PATH}; loopback-only; origin=${SKETCHUP_BRIDGE_ORIGIN}`)
}
