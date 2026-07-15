---
type: belief
id: frag-prototype-mode-panic-holes
provenance: introduced with feat(prototype) — ~[prototype] synthesizes @panic holes for unhandled terminals (400_160/400_161)
ts: 2026-07-14
---

# Prototype mode: run the incomplete program, panic loudly at the holes (belief)

`~[prototype]` is a per-file module opt-in that relaxes terminal-branch
exhaustiveness in BOTH directions (see "The dual" below): an unhandled required
`|` branch is no longer a KORU022 error, it becomes a synthesized `@panic` arm —
the SAME body an unhandled `| ?!` panic branch already gets — AND a handled arm
for a branch the event does not declare yet is no longer a KORU021/KORU030
error, it is tolerated and pruned. A half-shaped program compiles and runs the
paths that ARE built; a hole crashes loudly only if execution reaches it.

## The belief

Koru's exhaustiveness is not absolute at every altitude. The prior regime was:
a program compiles only when every required terminal is handled, and the sole
escape is a per-branch `| ?!` declaration. `~[prototype]` adds a MODE altitude —
it generalizes the `?!` honest-hole to every terminal at once. "Compile the
incomplete program, run what's built, panic at the holes" becomes a first-class
way to work, not a hack.

The guarantee is unchanged where it matters. Without the annotation the same
source is rejected KORU022 (400_161). The opt-in lives in the SOURCE, per-file
and greppable — there is deliberately no CLI flag a caller can pass to grant
leniency. "The language always demands totality" is now scoped to the
production altitude, not the language as a whole.

## The dual: undeclared branches slide too (the doodle direction)

Exhaustiveness has TWO directions, and `~[prototype]` relaxes both. The
missing-branch direction above ("every DECLARED terminal must be HANDLED") lets
you leave a handler out. The mirror direction — "every HANDLED branch must be
DECLARED" — lets you write a handler for a branch the event does NOT declare yet
(400_165). This is the top-down authoring story: sketch the handler flow the way
you actually reason about the program and let the event's terminal declarations
catch up later. An undeclared arm can never fire (the event never produces it),
so it has ZERO runtime footprint — it is pure declaration-debt, not a latent
panic. The declared path runs now; the undeclared arm is dropped from the
lowered switch.

The two directions are asymmetric in their failure shape, and that asymmetry is
the point. The missing-branch hole is a LATENT RUNTIME PANIC (a synthesized
`@panic` fires if reached). The undeclared arm is a PURE COMPILE-TIME GAP: it
never reaches runtime, so it costs nothing and simply records a to-do.

Both directions feed the GAP READOUT — a per-event report printed to stderr at
compile time for any prototype flow with gaps (`📋 prototype gaps — event 'X'`),
listing each `hole` (declared terminal unhandled → will `@panic`) and each
`undeclared` arm (handled, not declared → pruned). This makes the whole gap
surface visible WITHOUT exercising every path — the crucial gain over the
latent-panic-only regime, where a hole you never hit at runtime stayed invisible.
It is the machine-/human-readable frontier of "thought about, not built yet": the
surface for agentic gap-closing and for describing the events from exploratory
code. It is emitted where both sets are already in hand (auto-discharge synthesis)
— a first-cut home to lift into its own pass in a later tightening.

"The check" that must relax is not one place. The undeclared-branch wall stands
at four layers, each surfacing only once the prior clears — the post-comptime
cascade (branch sets can be comptime-constructed, so the wall is late): the
shared branch-checker (KORU021), the flow checker and shape checker that consume
it, the phantom semantic checker's produced-branch check (KORU030), and finally
the emitter — where the dual of hole-SYNTHESIS is hole-PRUNING: an undeclared
arm must be dropped, or it lowers to a `switch` case on a union tag that does not
exist and leaks a host Zig error. All four are terminal-only, parity with the
missing-branch relaxation. The production guarantee holds identically: remove
`~[prototype]` and the same source is rejected KORU021 (400_166).

## The release gate makes "cannot reach production" real (KORU029)

Leniency alone would be a rotting fallback: a `~[prototype]` module compiles
forever, so nothing forces the marker's removal ([[frag-no-fallbacks]] — every
fallback becomes the default). The release gate is the other half of the
bargain, and the thing that makes the whole feature legitimate: a `--release`
build **rejects outright** any module in the import graph bearing `~[prototype]`
(KORU029, `src/release_gate.zig`, the `check-release-gate` pass that runs FIRST
in analysis). Not "the holes error in release" — the *annotation itself* is
refused, before any lenient synthesis.

So the marker is greppable for humans AND build-breaking for CI: prototype code
physically cannot ship, because the release build refuses the file (400_162
entry, 400_164 transitive — an imported prototype dependency is rejected too;
400_163 confirms release leaves ordinary complete code alone). The dev workflow
of "run incomplete now" therefore always terminates in "handle every branch and
DELETE `~[prototype]`" before a release build can succeed — the gate is what
forces the deletion. `--release` is a *semantic* production signal (reject
dev-only constructs), orthogonal to optimize level (the final binary already
defaults to ReleaseFast with `--debug` as the opt-out).

The two halves are mechanically orthogonal: leniency lives inside the
checkers/auto-discharge; the gate is a separate top-level pass that only reads
module annotations and only fires under `--release`. Kept granular
(hardcoded `prototype`) rather than a general "release-forbidden annotations"
registry — one instance does not justify the framework; generalize when a
second forbidden annotation appears.

## Why the hole beats the stub — this is not a concession, it is the doctrine

The strictness had exactly one escape valve before this, and it was a liar:
`| required _ |> _`, a discarding stub written only to satisfy the exhaustiveness
checker. It typechecks as *handled* and is indistinguishable from a deliberate
drain — a silent fallback in the precise sense the language repudiates
([[frag-no-fallbacks]] / "assert, don't fall back"). It "fails silently forever."

The prototype hole is the *assert*, not the fallback: the branch you have not
written yet stays visibly absent in source and becomes a loud `@panic` if hit.
Give authors an honest escape valve and the dishonest one loses its reason to be
written. So prototype mode makes application code MORE honest, not less — the
same reason `| ?!` exists, lifted to a mode.

## Why terminals only, never effect arms

Prototype leniency covers TERMINAL (`|`) branches exclusively. Effect (`!`)
branches keep full exhaustiveness even under `~[prototype]`, because they do not
lower to switch arms — they lower to fns in the consumer's Handlers struct, and
a synthesized stand-in there is indistinguishable from a real install and would
corrupt presence truth (`@hasDecl(__H, ...)`; see
[[frag-presence-effect-arm-expressions]], 400_146/147/154). A missing effect arm
is worth less to skip and would break a load-bearing invariant, so it is out of
scope by design, not by omission.

## Where it lives (so the mechanism is findable, not restated)

One pure chokepoint gates the checker side: `BranchChecker.validateWithMode`
skips missing required terminals when prototype is set; `validate()` is a thin
wrapper passing false, so the ~19 existing callers are untouched. The shape and
flow checkers carry a `prototype_mode` field set from `module_annotations` in the
check-structure / check-flow passes. The loud arm is synthesized in
`auto_discharge_inserter` — a distinct list from `| ?!` panic branches, so
`--panic-branches=strict` (the crash-surface map) never governs prototype holes;
they are different features with different opt-ins.

## Open questions

- Fully-unhandled invocations (zero continuations written) still hit the
  structural KORU022 guards in the shape checker, not the `validate` path — so
  today prototype relaxes PARTIAL handling (some arms written, some left as
  holes), the representative "stub every branch" pain. Whether a zero-handler
  invocation should also become all-holes under `~[prototype]` is unruled.
- Nested / mid-pipeline invocations: synthesis is flow-head scoped. A hole on a
  nested branching step is not yet covered.
- JS target: the panic-hole lowering is designed against the Zig target; the JS
  equivalent (a `throw`) is unverified.
