---
type: belief
id: frag-a-stale-binary-lies-like-a-compiler-bug
provenance: diagnosed 2026-07-27 after reverting a correct merge on the strength of four wrong explanations
ts: 2026-07-27
---

# A stale `koruc` against a fresh `koru_std` produces symptoms indistinguishable from a compiler bug (belief)

Koru's two halves live on different clocks. `src/*.zig` is compiled **into**
`zig-out/bin/koruc`; `koru_std/*.kz` is read **at runtime** by that binary. A
`git merge`, `checkout`, or `revert` moves both files on disk instantly and
rebuilds nothing. Until `zig build` runs, every `koruc` invocation is an OLD
compiler reading a NEW standard library.

`/usr/local/bin/koruc` is a symlink into `zig-out/bin/`, so this is the default
state of the tool after any branch operation, not an exotic one.

## Why it reads as a compiler defect

The failure surfaces as **wrong emitted code**, which is precisely what a
compiler bug looks like. In the case that produced this belief, a merge landed a
new Stage-A pass and a `koru_std` change that depended on it. The binary was 45
minutes old and had no such pass, so the generated compiler contained zero
`__ret` bindings and `frontend_event.handler` fell off the end of a non-void
function. Every program failed, hello world included.

Four explanations were floated before the right one, each fitting the evidence:
the two desugar passes do not compose; zig's cache served a stale backend; the
suite ran before the last change; a guard declined the chain. All were about
what the compiler *does*. None asked **which compiler was running**. The
question that settles it in one command is `ls -l zig-out/bin/koruc` against the
mtime of `src/`.

`koru_std/compiler.kz` is where this bites hardest, because it is the one place
a rule implemented in `src/` is exercised *solely* through `koru_std/` — so a
skew there breaks self-hosting while leaving hand-written tests green.

## Why the suite never shows it

`run_regression.sh` runs `zig build` and exits on failure before any test. A
suite run therefore cannot observe this state; it rebuilds out of it. Only a
hand-run `koruc` — the fast probe reached for precisely when a suite feels too
slow — sees it. **The convenient measurement is the only one that can lie**, and
it lies most loudly right after the operation most likely to cause it.

## The discipline, and the mechanism it substitutes for

`zig build` before any hand probe that follows a tree operation, or run the
suite and let it do the same. Prefer the suite when the answer matters.

The mechanism that would retire the discipline: stamp `koruc` at build time with
a hash of the `src/` it was compiled from, and have it compare that against the
tree it is reading `koru_std/` out of — failing loudly on skew rather than
silently emitting a compiler that cannot return. Not built; a design call, not a
thing to slip in.

## Related

Same family as `frag-tests-and-compiler-coevolve` — two artifacts that must move
together, with nothing enforcing that they did. Here the two are the compiled
compiler and the stdlib it reads, and the enforcement gap is a build step no one
is obliged to run.
