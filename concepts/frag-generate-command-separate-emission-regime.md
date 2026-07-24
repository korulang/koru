---
type: belief
id: frag-generate-command-separate-emission-regime
provenance: 2026-07-18 session with Lars — C-first parser generation, parser-generate-c worktree
ts: 2026-07-18
---

# `generate` — a target backend is a COMMAND that breaks out of the pipeline, not a pipeline contaminant (belief)

Lowering a grammar to a foreign language (C first) does NOT run through the
normal emission pipeline, and must not contaminate it. The target backend is a
`[comptime|command]` (the std/compiler command contract) that runs INSTEAD of
compilation: the backend dispatches it before `koru_coordinate`, so no pipeline
pass fires. It reads the grammar region straight out of the program AST — the
same continuations `parse` compiles — and drives its OWN emitter, writing a
self-contained artifact (a `.c`/`.h`) exposing a FIXED foreign API. Lars's
framing (2026-07-18): "a whole separate emission regime… I am NOT suggesting we
contaminate our existing emission pipeline."

**Why a command, not `--lang`.** The `--lang`/`CompilerEnv.lang` machinery
([[frag-compiler-flags-baked-into-backend]]) drives the WHOLE-program emitter — it
needs a Koru→<lang> emitter for the entire program (exists for js, absent for c).
A parser needs none of that: its I/O is trivial (bytes in; accept / value /
furthest-failure out), so it exposes as a plain foreign API and the hand-back into
the rest of a Koru program DISSOLVES. That dissolution is exactly what makes C
reachable with NO whole-program Koru→C emitter. `--lang` is therefore not hoisted
into the pipeline; the command reparses its own argv, and the compiler's own
`--lang` parse is inert on the command path (it broke out before emission reads
it).

**A target = a vocabulary table, not a new algorithm.** The descent algorithm
(recursive descent, DFA terminals, first-byte gate, same-head factoring,
furthest-failure — see [[frag-parser-library-peg-on-two-glyphs]]) is TARGET-BLIND.
Re-expressing it in a new language is a small vocabulary swap: the slice
representation (fat-pointer vs `(ptr,len)`), the nullable encoding (`?T` vs
bool-return + out-param + a `SIZE_MAX` sentinel), string escaping, labeled-break
spelling (native block-break vs `goto`). Those are the ONLY per-target decisions;
everything else keeps its shape. That is why the first C backend was thin, and it
predicts the next target is another vocabulary table, not another emitter.

**The prediction held — and the table has one entry nobody listed: the HOST
LANGUAGE'S OWN STRICTNESS.** The Zig backend confirmed the vocabulary-swap
thesis (slice = native `[]const u8`, nullable = `?ParseResult`/`?usize`,
labeled-break = `break :Lx` out of a labeled block — a direct native stand-in
for C's forward `goto Lx_end`). But one C idiom that *looked* target-blind is
not: the emitter's blind always-discard. `(void)x;` is harmless in C whatever
happens later, so the C path emits it unconditionally; Zig 0.15 makes a
pointless discard of a later-used local a HARD COMPILE ERROR. The Zig backend
must therefore decide provable-unusedness — from the AST facts codegen already
holds (which alt binds, whether a tail produced), plus a token-boundary text
scan for the one case AST shape cannot settle (whether a produce expression
happens to mention a bound name).

The general form: a per-target decision is not only *how do I spell this
construct* but *what will this host reject that C tolerated*. C is the
permissive floor, so anything written against it silently encodes C's
tolerances as if they were universal. A fourth backend should re-derive the
discard discipline rather than inherit it, and should expect the same class of
surprise anywhere the C emitter is unconditionally permissive.

**The raw-seed-AST seam (load-bearing).** A command runs on the seed AST BEFORE
`resolve-with-scopes` — which lives in `coordinate` and is therefore bypassed. So
the `[with]`-opened grammar verbs (`sub`/`lit`/`match`) arrive stamped with the
MAIN module, not `std/parser`. A command-side grammar reader must match verbs by
SEGMENT NAME inside the validated region, never by the resolved qualifier a
transform (which runs after resolution) can rely on. This is the general seam
between what a command sees and what a pipeline pass sees — every future
AST-consuming command inherits it.

Landed C-first on the `parser-generate-c` worktree: `koruc <grammar>.k generate c`
writes a standalone C parser; the SHOWN correctness battery and the details live
in the commit, not here. Open (Lars to steer): how to pin a C-emitting command as
a regression test — a NEW test kind (emit → `cc` → run → diff), which the harness
has no shape for yet — and the next target (js as another vocabulary table) vs
deepening grammar features first.
