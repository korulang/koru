---
type: belief
id: frag-store-is-a-transform-not-a-runtime-library
provenance: JS-parity frontier mapping — std/store's ten procs read as `~[transform]proc`, contradicting the runtime-library reading that had made contract extraction a prerequisite for the highest-leverage module
ts: 2026-08-06
---

# `std/store` is a compile-time transform, so JS parity does not owe it a runtime port

Planning the JavaScript target, we read `std/store` as the big runtime
library: 8.7 KLOC, the largest module in the stdlib, and therefore the
expensive part of any port. That reading made it the worst-conditioned work
in the project — it sat behind the contract-extraction prerequisite (a
`.kz` must be split into `.k` + `.kz` before a `.kjs` sibling can exist),
and porting it looked like reimplementing a database in JavaScript.

The module contradicts that. **All ten of its procs are
`~[transform]proc`**, with `new` declared
`~[keyword|comptime|transform]pub tor`. `std/store` is not a library a
program calls at runtime — it is a code generator that expands at compile
time. `std/store:new(...)` in user source is not a call; it is an
expansion site.

Two consequences follow, and they point the same way:

**The contract-extraction prerequisite does not apply to it.** The facet
split is by the body's host language (`frag`-adjacent ruling, grounded at
`io.kz:1726-1728`: a transform's `|js` body "produces JS output, body is
structurally Zig"). A transform body is always Zig, so it stays in `.kz`.
There is no `.kjs` to create and therefore no `.k` contract to extract
first. The module that blocks the most tests — 153, and 122 of them
solely — is the one module that skips the prerequisite entirely.

**The performance thesis and the cheap path are the same path.** The claim
that Koru-on-JS would give SPA state management performance unavailable to
other libraries rests on producer-side fusion. Fusion is a compile-time
property, and the transform architecture already delivers it: the port is
teaching an existing generator to emit JavaScript instead of Zig, not
re-deriving the fusion in a new runtime.

The belief this leaves us with: **module size is not a proxy for port cost
on a code-generating stdlib.** Before sizing any module's port, read
whether its procs are runtime or transform — the two carry different
prerequisites, different skills, and different risk, and a line count says
nothing about which one you are looking at. The corpus currently holds 152
runtime procs against 23 transform procs; summing them into a single
"stdlib coverage" number would hide exactly this distinction.

Open question: whether a transform's `|js` variant can share the Liquid
template-parsing logic with its `|zig` sibling and diverge only at the
output shape — `print.blk|js` (io.kz:1737) is currently a stub that ignores
template content and emits a fixed `console.log`, and its own comment
proposes the shared-logic route without having taken it. If that sharing
holds, 23 transform ports are far cheaper than 23 rewrites; if it does not,
the transform half is the harder half despite being the unblocked one.
