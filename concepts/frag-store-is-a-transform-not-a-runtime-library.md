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
nothing about which one you are looking at.

**And reading the proc line does not tell you.** A proc inherits its
transform-ness from the event it implements, and the annotation is
frequently written on the event rather than on the proc:
`koru_std/kernel.kz:80` declares
`~[comptime|transform|claims_descendants]pub tor init`, then `:90` writes a
bare `~proc init|zig`. Classifying on the proc line alone tagged
`kernel:init` a portable runtime port worth 27 tests, when it is the
Zig-only MLIR/GPU backend that must never be ported at all — the single
worst place the plan could have spent effort, promoted to fourth on the
priority list by a one-line resolution bug.

Correcting it moved the corpus from 152 runtime / 23 transform to **118
runtime / 57 transform**: 34 procs reclassified, and with them 34 procs'
worth of contract-extraction prerequisite that was never owed. Summing the
two into one "stdlib coverage" number would hide the distinction; deriving
the distinction from the wrong line hides it just as effectively while
looking precise.

Open question: whether a transform's `|js` variant can share the Liquid
template-parsing logic with its `|zig` sibling and diverge only at the
output shape — `print.blk|js` (io.kz:1737) is currently a stub that ignores
template content and emits a fixed `console.log`, and its own comment
proposes the shared-logic route without having taken it. If that sharing
holds, 23 transform ports are far cheaper than 23 rewrites; if it does not,
the transform half is the harder half despite being the unblocked one.
