import { defineConfig } from 'vitest/config'

/** Focused Node-side tests for the SketchUp bridge protocol and carrier. */
export default defineConfig({
  test: {
    include: ['tests/**/*.spec.ts'],
  },
})
