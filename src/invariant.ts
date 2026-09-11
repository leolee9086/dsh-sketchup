/** Package-owned invariant companion for the SketchUp bridge. */

import type { Context } from '@deepseek-ai/cordis'
import type { InvariantInstaller } from '@deepseek-ai/dsh-invariants'

const PACKAGE_NAME = '@leolee9086/dsh-sketchup'

/** Loader-visible companion name. */
export const name = 'bridge-sketchup-invariant'

/** The invariant service is optional to the normal bridge runtime. */
export const inject = ['invariants']

/** The carrier is instance-local; protocol and lifecycle tests cover its contract. */
const install: InvariantInstaller = () => {}

/** Reserve package ownership in the Host invariant registry. */
export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))
