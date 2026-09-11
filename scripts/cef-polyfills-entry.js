// This bundle runs in the embedded browser, never in the Node Host.
// Use maintained, feature-detected implementations for standard ECMAScript APIs:
// Iterator helpers, Set operations, array copy methods, grouping, RegExp.escape,
// Promise.withResolvers, well-formed strings, typed arrays and disposal symbols.
import 'core-js/stable/index.js';
