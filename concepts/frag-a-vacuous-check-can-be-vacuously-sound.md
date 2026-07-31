---
type: belief
id: frag-a-vacuous-check-can-be-vacuously-sound
provenance: confirming the purity checker's unpopulated proc call graph 2026-07-31 — the commissioned defect ("a [pure] proc calling an impure proc passes vacuously") turned out to be unwritable in the language, because the only spelling of a proc-body dispatch is the inline flow and the parser refuses it (KORU003, pinned by 210_065)
ts: 2026-07-31
---

# A vacuous check over an empty domain is sound — fix it for the day the domain fills (belief)

The purity checker registered every proc in a call graph and never populated
it, so its transitive check accepted every `[pure]` proc without looking at
anything. Read in isolation, that is the classic vacuous wall —
[[frag-a-check-that-cannot-match-reports-clean]]'s shape inside a compiler
pass. But the count came back different this time: the domain the check
quantifies over is *empty by construction*. A Koru proc body is an opaque host
string; the one surface that would put an edge in that graph — an inline flow
inside a proc body — is feature-gated off at parse. No parseable program can
express the violation the check fails to catch. The check was vacuous AND the
language made the vacuity sound.

That changes the verdict on the fix, not the need for it. The wrong move is a
new refusal surface justified by a defect no program can exhibit — that
invents enforcement the design record explicitly parks (PURITY-TRACKING.md:
"verification surface TBD"). The right move is to make the analysis
correct-by-construction over the surface it CAN see (populate the graph from
`proc.inline_flows`, mirror the flow arm's unknown-callee conservatism) and
pin the mechanism at the unit level, where the gate can be bypassed by
grafting an AST. The machinery is then load-bearing the instant the gate
lifts, instead of the gate-lift silently inheriting a vacuous check.

The sibling lesson from the same session: the fixed point walked only
top-level items while imports land as module_decl items before the pass runs.
That half was NOT vacuously sound — every module-level `[pure]` proc was
misreported as transitively impure in the serialized AST. One unpopulated
structure, two verdicts: soundness depends on what feeds the structure, not
on the structure's emptiness.

## The test this leaves behind

Before declaring "this check is vacuous, therefore broken": name the program
that reaches it. If no legal program can, the defect is in *readiness*, not
correctness — fix it as groundwork, pin it at whatever level can express the
case, and do not mint user-facing enforcement for an unreachable state.
