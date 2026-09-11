# CEF compatibility

SketchUp 2024's embedded Chromium can be older than the JavaScript APIs used by the current Harness client. The native-window prelude installs `core-js/stable` before the deferred application module graph evaluates. The bundle is compiled to Chromium 80 syntax and embedded in the Host artifact; it does not fetch a CDN script or patch the Node process. Ordinary browser tabs return before any polyfill executes.

Covered standard APIs include Iterator and synchronous iterator helpers, Set operations, non-mutating array methods, Object/Map grouping, Promise.withResolvers, RegExp.escape, well-formed string methods and typed-array additions. AbortSignal.any remains a separate browser shim. `window.__DSH_CEF_COMPAT__` reports the monitored missing APIs before/after installation without including session or model data.

Run `pnpm test` and `pnpm run build`. Tests simulate missing APIs in an isolated JavaScript realm and verify iterator closure, Promise resolution, set operations, source-array immutability, and ordinary-browser isolation. A successful build alone does not update the running Host. Restart DSH and refresh the SketchUp WebView, then verify that the loader completes.

Limits: JavaScript polyfills do not upgrade CEF syntax parsing, CSS layout, graphics, codecs or privileged browser APIs. Web Workers have a separate global realm and need their own compatibility strategy if a worker reports missing APIs. API feature checks and real WebView checks remain necessary when new Harness modules are added.

Third-party code: core-js is copyright (c) Denis Pushkarev and is MIT licensed. Its unmodified license is distributed at `THIRD-PARTY/core-js-LICENSE`. Source: https://github.com/zloirock/core-js .
