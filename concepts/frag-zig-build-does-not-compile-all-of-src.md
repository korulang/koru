---
type: belief
id: frag-zig-build-does-not-compile-all-of-src
provenance: merge of main into js-w2 — `zig build` reported success on a tree where src/js_emitter.zig had an undeclared identifier; the scan then failed 70/70 with that Zig compile error
ts: 2026-08-06
---

# `zig build` certifies the compiler binary, not `src/` — three files are outside it

`zig build` is the reflex for "did my edit compile", and for almost every file
in `src/` it answers correctly. It does not answer for all of them, and it fails
by reporting **success**.

Measured, not inferred: `build.zig` names **73** `src/*.zig` files. The
generated-backend build assembled by `koru_std/compiler.kz` names **44**. Three
are in the second list and not the first:

    src/continuation_codegen.zig
    src/js_emitter.zig
    src/release_gate.zig

Those three reach a compiler only through `koru_std/compiler.kz:509`, which
builds them per test as part of the backend. `zig build` never sees them. A
syntax error, a type error, a renamed variable left dangling by a merge — all
of it passes the top-level build untouched and surfaces later, at whatever
moment a test first drives that path.

This is the mirror of the stale-binary trap
(`frag-a-stale-binary-lies-like-a-compiler-bug`): there, a build you did not run
made a fresh tree behave like a broken compiler. Here, a build you *did* run
tells you a broken tree is fine. Both put a green where the tree is red, and
both are properties of the same two-clock arrangement — `src/*.zig` compiled
into `koruc`, and `src/*.zig` compiled again, differently, by the backend the
compiler generates.

**The operational rule this leaves:** after editing one of those three, or after
any merge that touches them, `zig build` is not evidence. Drive one fixture
through the path — `koruc <fixture>/input.kz --lang=js` for the emitter — and
read the result. That took 4 seconds and would have caught the case that
produced this belief; instead a clean `BUILD_OK` was believed, work continued on
top of it, and the defect surfaced as **70 of 70 tests failing at once** with
`error: use of undeclared identifier 'best_op_branch'` — a shape that reads like
catastrophe and was one dangling name from a three-way merge.

The wider point is about what a check's silence means. A green from a tool that
does not examine the thing you changed is not weak evidence, it is *no*
evidence, and it is more dangerous than no check at all because it consumes the
suspicion that would otherwise have gone looking.

Open question: whether the three belong in `build.zig` as a compile-only check.
Nothing in the top-level binary links them, so adding them is not free — it
would be a deliberate "compile this for the diagnostics, discard the artifact",
and someone should decide that on purpose rather than have it arrive as a side
effect of fixing this note.
