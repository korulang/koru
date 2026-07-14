---
type: belief
id: frag-prototype-mode-panic-holes
provenance: introduced with feat(prototype) — ~[prototype] synthesizes @panic holes for unhandled terminals (400_160/400_161)
ts: 2026-07-14
---

# Prototype mode: run the incomplete program, panic loudly at the holes (belief)

`~[prototype]` is a per-file module opt-in that relaxes terminal-branch
exhaustiveness: an unhandled required `|` branch is no longer a KORU022 error,
it becomes a synthesized `@panic` arm — the SAME body an unhandled `| ?!` panic
branch already gets. A half-shaped program compiles and runs the paths that ARE
built; a hole crashes loudly only if execution reaches it.

## The belief

Koru's exhaustiveness is not absolute at every altitude. The prior regime was:
a program compiles only when every required terminal is handled, and the sole
escape is a per-branch `| ?!` declaration. `~[prototype]` adds a MODE altitude —
it generalizes the `?!` honest-hole to every terminal at once. "Compile the
incomplete program, run what's built, panic at the holes" becomes a first-class
way to work, not a hack.

The guarantee is unchanged where it matters. Without the annotation the same
source is rejected KORU022 (400_161). The opt-in lives in the SOURCE, per-file
and greppable — there is deliberately no CLI flag a caller can pass to grant it,
so prototype leniency cannot leak into a production build by someone else's
invocation. "The language always demands totality" is now scoped to the
production altitude, not the language as a whole.

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
