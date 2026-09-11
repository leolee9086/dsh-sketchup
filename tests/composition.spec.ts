/**
 * Loader-level smoke test: mount the real webserver, tool registry, and bridge
 * package together, then exercise the local Origin-gated WebSocket route.
 */

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import Include from '@deepseek-ai/cordis-plugin-include'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import WebServer from '@deepseek-ai/dsh-host-webserver'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRegistry from '@deepseek-ai/dsh-tools'
import WebSocket from 'ws'
import * as BridgeSketchup from '../src/index.ts'
import { SKETCHUP_BRIDGE_ORIGIN } from '../src/protocol.ts'

const BRIDGE = '@leolee9086/dsh-sketchup'

let root: string | undefined
let context: Context | undefined

afterEach(async () => {
  await context?.fiber.dispose()
  context = undefined
  if (root !== undefined) await rm(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 20 })
  root = undefined
})

function connect(port: number): Promise<{ ws: WebSocket; frames: unknown[] }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ext/sketchup`, { headers: { origin: SKETCHUP_BRIDGE_ORIGIN } })
    const frames: unknown[] = []
    ws.on('message', (data) => frames.push(JSON.parse(data.toString())))
    ws.once('error', reject)
    ws.once('open', () => resolve({ ws, frames }))
  })
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const started = Date.now()
  while (!predicate()) {
    if (Date.now() - started > 2_000) throw new Error('composition wait timed out')
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

describe('bridge-sketchup composition', () => {
  it('mounts tools and serves the local Origin-gated route through Loader', async () => {
    root = await mkdtemp(join(tmpdir(), 'dsh-bridge-sketchup-'))
    const configPath = join(root, 'cordis.yml')
    await writeFile(configPath, [
      "- name: '@deepseek-ai/dsh-host-webserver'",
      '  config:',
      "    host: '127.0.0.1'",
      '    port: 0',
      "- name: '@deepseek-ai/dsh-system-prompt'",
      "- name: '@deepseek-ai/dsh-tools'",
      `- name: '${BRIDGE}'`,
      '  config:',
      '    maxHistoryEvents: 20',
      '',
    ].join('\n'))

    context = new Context()
    context.baseUrl = pathToFileURL(root).href + '/'
    await context.plugin(Loader)
    context.loader.builtins.include = Include
    context.loader.internal = {
      version: 'v2',
      async import(specifier: string) {
        const modules = new Map<string, unknown>([
          ['@deepseek-ai/dsh-host-webserver', WebServer],
          ['@deepseek-ai/dsh-system-prompt', SystemPrompt],
          ['@deepseek-ai/dsh-tools', ToolRegistry],
          [BRIDGE, BridgeSketchup],
        ])
        if (!modules.has(specifier)) throw new Error(`unexpected Loader import: ${specifier}`)
        return modules.get(specifier)
      },
    } as unknown as NonNullable<typeof context.loader.internal>
    await context.loader.create({ name: 'cordis:include', config: { path: pathToFileURL(configPath).href } })
    await context.loader.await()

    const web = context.get('webServer') as typeof WebServer.prototype
    const tools = context.get('tools') as ToolRegistry
    for (const name of ['sketchup_status', 'sketchup_snapshot', 'sketchup_history', 'sketchup_execute', 'sketchup_write_plugin']) {
      expect(tools.get(name)).toBeDefined()
    }

    const configResponse = await fetch(`http://127.0.0.1:${web.port}/ext/sketchup-config`)
    expect(configResponse.status).toBe(200)
    const config = await configResponse.json() as Record<string, unknown>
    expect(config).toMatchObject({
      origin: SKETCHUP_BRIDGE_ORIGIN,
      wsUrl: `ws://127.0.0.1:${web.port}/ext/sketchup`,
      protocol: 1,
    })
    expect(config).not.toHaveProperty('tokenFile')

    const client = await connect(web.port)
    client.ws.send(JSON.stringify({
      t: 'hello',
      caps: { client: 'sketchup-ruby', protocol: 1, instanceId: 'sketchup-composition-1', features: ['snapshot'] },
    }))
    await waitFor(() => client.frames.some((frame) => (frame as { t?: string }).t === 'hello.ok'))
    expect(client.frames).toContainEqual(expect.objectContaining({ t: 'hello.ok' }))
    client.ws.close()
  })
})
