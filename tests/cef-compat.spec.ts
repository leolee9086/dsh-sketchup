import { createContext, runInContext } from 'node:vm'
import { describe, expect, it } from 'vitest'
import { injectSurfacePrelude } from '../src/surface.ts'

const html = injectSurfacePrelude('<html><head><script type="module" src="/app.js"></script></head><body></body></html>')
const script = html.match(/<script data-dsh-sketchup-surface>([\s\S]*?)<\/script>/)?.[1]
if (!script) throw new Error('CEF prelude not found')

function legacy(native = true) {
  const ctx = createContext({ console })
  runInContext(`
    globalThis.window = globalThis;
    window.name = ${JSON.stringify('dsh-sketchup:sketchup-test-compat')};
    ${native ? '' : "window.name = '';"}
    window.navigator = { onLine: true };
    window.fetch = async () => ({ok:true, json:async () => ({connected:true})});
    window.dispatchEvent = () => true;
    globalThis.CustomEvent = class { constructor(type) {this.type=type} };
    globalThis.document = { readyState:'loading', documentElement:{setAttribute(){}}, addEventListener(){}, getElementById(){return null} };
    delete globalThis.Iterator;
    delete Array.prototype.toSorted; delete Array.prototype.toReversed;
    delete Array.prototype.with; delete Array.prototype.toSpliced;
    delete Set.prototype.union; delete Set.prototype.intersection;
    delete Set.prototype.difference; delete Object.groupBy; delete Map.groupBy;
    delete Promise.withResolvers; delete RegExp.escape;
  `, ctx)
  return ctx
}

describe('CEF standard API compatibility', () => {
  it('installs iterator helpers, set methods and non-mutating arrays before app code', () => {
    const ctx = legacy()
    runInContext(script, ctx)
    expect(runInContext(`JSON.stringify(Iterator.from([1,2,3]).map(x=>x*2).filter(x=>x>2).toArray())`,ctx)).toBe('[4,6]')
    expect(runInContext(`JSON.stringify([...[1,2].values().map(x=>x+1)])`,ctx)).toBe('[2,3]')
    expect(runInContext(`JSON.stringify([...new Set([1,2]).union(new Set([2,3]))])`,ctx)).toBe('[1,2,3]')
    expect(runInContext(`JSON.stringify(new Set([1,2]).difference(new Set([2])).values().toArray())`,ctx)).toBe('[1]')
    expect(runInContext(`const a=[3,1,2]; JSON.stringify([a.toSorted(),a,a.with(0,5)])`,ctx)).toBe('[[1,2,3],[3,1,2],[5,1,2]]')
    expect(runInContext(`JSON.stringify(Object.groupBy([1,2,3],x=>x%2))`,ctx)).toBe('{"0":[2],"1":[1,3]}')
    expect(runInContext(`typeof RegExp.escape`,ctx)).toBe('function')
    expect(runInContext(`JSON.stringify(__DSH_CEF_COMPAT__.missingAfter)`,ctx)).toBe('[]')
  })
  it('preserves Promise resolution and iterator close semantics', async () => {
    const ctx=legacy(); runInContext(script,ctx)
    await expect(runInContext(`const gate=Promise.withResolvers();gate.resolve(42);gate.promise`,ctx)).resolves.toBe(42)
    expect(runInContext(`let closed=false; function* values(){try {yield 1;yield 2;}finally{closed=true}} Iterator.from(values()).some(x=>x===1);closed`,ctx)).toBe(true)
  })
  it('does not patch ordinary browser tabs', () => {
    const ctx=legacy(false);runInContext(script,ctx)
    expect(runInContext(`typeof Iterator`,ctx)).toBe('undefined')
    expect(runInContext(`typeof Array.prototype.toSorted`,ctx)).toBe('undefined')
  })
  it('injects once and does not terminate the inline script early', () => {
    expect(injectSurfacePrelude(html)).toBe(html)
    expect(script).not.toMatch(/<\/script/i)
    expect(html.indexOf('data-dsh-sketchup-surface')).toBeLessThan(html.indexOf('</head>'))
  })
})
