---
type: belief
id: frag-a-transform-proc-had-no-js-variant-machinery
provenance: regex JS port + the print.blk decl-site trap it left behind
ts: 2026-08-06
tags: [js-target, transform]
resource: src/js_emitter.zig (emitEventDecl)
---

# A transform's `|js` variant is never runtime code — at the decl-site handler either

The JS-target plan treats a transform port as work inside the `.kz`: write a
`|js` rendering beside the `|zig` one, diverging where output text is produced.
That is the right SHAPE — but a `|js` on a transform means "this variant EMITS
JavaScript", NOT "this body is JavaScript". The body is Stage-C host (Zig) code
that runs inside the compiler and has no runtime existence. That seam is the
source of a recurring bug: splice a transform variant's body where runtime
JavaScript is expected and the emitted program contains `@import("ast")` and node
refuses the file.

The two-things trap fires in **both** places a transform variant can be reached:

- **The call-site splice** (`findJsProcIn`): inlining a `[transform]proc` body as
  if it were a runtime handler. Fixed 2026-08-06 by skipping `[transform]` procs.
- **The decl-site handler** (`emitEventDecl`): every event decl in scope gets a
  `<name>_event` key, and for a transform tor that key is dead code — the
  transform's inline output replaced every call site — but the emitter still
  spliced the variant body into it. That is the bug that shipped after the first
  fix: the first fix keyed on `proc.annotations` containing "transform", which is
  true only for `~[transform]proc` variant declarations (regex's `match`/`scan`).
  A transform tor declared as `~[comptime|transform]pub tor` with a PLAIN `~proc
  name|js` variant (io.kz's whole print family, `print.blk` chief among them) has
  `annotations: []` on the proc — the parser does NOT propagate the tor's
  annotations to its variant procs. The guard never fired; the |js body's Zig
  landed in the emitted JS and `010_000_hello_world_koru` (a `print.blk`) failed
  `js-runtime` at a `SyntaxError` on line 16.

The fix: key on the EVENT DECL's annotations (`event.annotations`), not the
proc's — the Zig emitter already reads the event for exactly this reason
(visitor_emitter.zig:3923). A `[transform]` tor gets a throw-stub decl-site
handler ("lowered at compile time and must never be called"), mirroring the
`|template` stub; the runtime surface is the transform's inline output alone.

**And the original lesson, sharpened:** `print.blk|js` working was NOT evidence
that transform `|js` variants worked — and it was not even working. It was the
failing shape all along: a plain `~proc` variant of a transform tor, invisible to
a fix that only covered `[transform]proc` declarations. A single green precedent
says the path is open for programs shaped like the precedent, and nothing more.
`[transform]proc` variants and plain-proc variants of a transform tor are TWO
shapes the machinery must carry; after 2026-08-06 it carried one of them, and the
board's `js-runtime` failures were the other, silently. When porting a transform,
check the machinery carries the exact declaration shape you wrote — by BUILDING it
against the JS target, not by reading the `.kz`.