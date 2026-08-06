---
type: belief
id: frag-zig-build-does-not-compile-the-js-emitter
provenance: the JS target was wholly broken on main by a type error in js_emitter.zig that `zig build` reported as success; found only when a one-line smoke scan failed
ts: 2026-08-06
---

# `zig build` does not compile the JS emitter, so it cannot green-light one

`zig build` builds `koruc`. **`src/js_emitter.zig` is not part of that
compilation unit.** It is declared as its own module in `build.zig` and linked
into the *per-test backend* build, which only happens when a test actually
compiles — and, for the JS path, only under `--lang=js`. A type error in the JS
emitter is therefore invisible to `zig build`, which exits 0 while the entire
JavaScript target is dead.

That is not a hypothetical. `emitProcBodyWithSplicedEffectCalls` held a variable
retyped from `?*const ast.Continuation` to `?*const ast.Branch` without its use
site being updated; the use site still read `cont.branch` and `cont.binding`,
which do not exist on a `Branch`. Every `koruc --lang=js` invocation in the tree
failed to build its backend. The simplest fixture in the corpus — a single event
printing one line — went red. `zig build` said nothing.

The belief this leaves us with: **an acceptance criterion must exercise the
artifact it claims to cover.** "`zig build` succeeds" is a real check of the
compiler binary and a *null* check of the emitter, and the two were conflated in
eight contestant briefs written by the same person who then merged the result.
Every contestant satisfied the criterion honestly. The criterion was wrong.

The correct smoke test costs about ten seconds and is unambiguous: compile ONE
known-green fixture with `--lang=js` and run it. `js-scan --tests` over a
single-line file does exactly this. Any brief whose subject is the JS emitter
must require that and not `zig build`.

The general form is worth more than the instance. A build system with per-target
or per-consumer compilation units has **as many "does it compile" questions as it
has units**, and the top-level build command answers only its own. Whenever a
brief says "it builds", ask which unit — and if the artifact under change is not
in that unit, the check is decoration.

Open question: whether the JS emitter should be pulled into `zig build` as a
compile-only target so the fast loop covers it. The argument against is that it
is genuinely a backend-side module and forcing it into the frontend build
misrepresents the architecture; the argument for is that ten seconds of feedback
beats an accurate module graph nobody's tooling reads. Unresolved, and the
cheap smoke test makes it non-urgent rather than settled.
