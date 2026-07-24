// JS-emitter bug pin: dispatch-binding name shadows a local in the calling
// proc body, producing `const c = c;` in the inlined dispatch block — a
// ReferenceError (TDZ) at runtime in JS.
//
// The proc body has a local `c` it passes to the effect call. The dispatch
// line binds the payload to a name *also* called `c`. js_emitter inlines:
//
//     const c = ...;        // local from proc body
//     { const c = c; ... }  // BUG: inner const shadows but RHS hits TDZ
//
// Zig emits a closure-passing trampoline (`__H.key(c)`) so no inlined block,
// no collision — Zig path passes. JS path crashes.
//
// Fix shape: the JS emitter should rename the dispatch binding when it
// collides with a local at the call site, OR skip the binding emit when the
// payload expression IS the binding name (`const c = c` is a no-op).
pub tor run { n: u64 }
! key u64
pub tor onKey { ch: u64 }
pub tor report {}

run(n: 1)
! key c |> onKey(ch: c)
report()
