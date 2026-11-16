---
type: belief
id: frag-module-scope-is-column-zero-not-brace-depth
provenance: t42 KORU112 commission — koru-rive bg-arm deletion left an
  orphan `}`; depth drift flagged fn locals 'k'/'m'/'ring' as module
  decls in an unrelated proc (400_159 pins the valid-file twin via a
  `\\` multiline string carrying `}`)
ts: 2026-11-16
---

# Module scope in opaque host text is column zero, not a brace count

Checks that ask "is this host line a module-level declaration" cannot
trust a running brace-depth counter over host text. Host lines are
opaque to the parser — emitted verbatim, validated only later by the
host's own compiler — so the counter sees every `{`/`}` the host will,
plus the ones the host will NOT: braces inside `\\` multiline strings,
and orphan closers left by a partial edit. One miscount does not error;
it *drifts*, and every line after reads one level shallow or deep.

KORU112's `checkModuleScope` accumulated `braceDepthChange` across all
host lines and treated `depth == 0` as module scope. An orphan `}` in
koru-rive's `rive/index.kz` (a bg-paint arm deleted minus its outer
close) drove the count to -1; every later `fn {` then landed its body
at depth 0, so fn-local `var k` / `var m` / `var ring` became phantom
module declarations — and an unrelated effect-branch proc using `k` as
a loop capture was rejected with "write `$mod.k`". The file was
invalid Zig anyway; the diagnostic was noise on top of the real brace
error, pointing at the wrong file region entirely.

The ruling: module decls are *unindented*. `at_module_scope` now
requires `depth == 0` **and** no leading whitespace — depth stays as
the guard against column-0 lines inside unclosed functions (sloppy
host style), column zero is the direct signal that survives drift.
The check errs toward silence under broken input: a missed KORU112
degrades to the host compiler's own error, a false one blocks valid
code with a wrong diagnosis.

What this does NOT fix: drift can still hide *real* module decls
(fn names at depth -1 are skipped), and `braceDepthChange` still does
not know `\\` strings — the column guard makes those misses silent
rather than wrong, which is the correct failure direction for a wall
whose false positive costs more than its false negative.
