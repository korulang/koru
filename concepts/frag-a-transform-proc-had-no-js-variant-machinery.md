---
type: belief
id: frag-a-transform-proc-had-no-js-variant-machinery
provenance: regex JS port — three compiler walls stood between a `|js` transform rendering and a compiling backend, none of them in regex
ts: 2026-08-06
---

# Porting a transform to JavaScript was never only a stdlib job

The JS-target plan treats a transform port as work inside the `.kz`: write a
`|js` rendering beside the `|zig` one, diverging where output text is produced.
That is the right SHAPE, and it is what `declarations.kz`'s two template
renderings look like. What the plan assumed — and nobody had tested — is that the
compiler could already carry such a variant end to end.

It could not, for the shape most of the stdlib actually uses.

Three walls, discovered in sequence, each hidden behind the previous one:

- **A `[transform]proc`-shaped event emitted no variant handlers at all.** The
  emitter short-circuits to a dedicated override for events implemented by
  `~[transform]proc`, and that override emitted its one proc and returned,
  never reaching the general variant loop. The dispatcher, on a different code
  path, wrote `handler__js` branches anyway. The two halves disagreed and the
  backend failed to compile.
- **A transform's `|js` body was spliced as if it were runtime JavaScript**,
  putting `@import("ast")` into the output. This is the `|js`-means-two-things
  trap, sitting in one function that keyed on the tag alone.
- **Host declarations a transform appends were dropped in silence** on the JS
  side while being emitted on the Zig side, so the dispatch called matcher
  functions that were never defined.

The belief worth carrying: **`print.blk|js` working was not evidence that
transform `|js` variants worked.** It is a plain `~proc`, so it misses the
override that broke everything else — the one existing example was the one
example that could not have caught the bug. A single green precedent says the
path is open for programs shaped like the precedent, and nothing more.

The consequence is forward-looking and load-bearing: **the store and kernel
JS renderings were blocked on this and nobody knew.** Both are
`[transform]proc`-shaped, as are grid, field, constructor, trellis and parser.
Any estimate of those ports made before this landed was measuring the `.kz` work
only, and the compiler work in front of it was invisible — not large, as it
turned out, but strictly prior. When planning a port, check that the machinery
carries the shape you are about to write, and check it by BUILDING one, because
the surface that proves it is exactly the surface that does not exist yet.
