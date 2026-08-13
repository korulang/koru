---
type: belief
id: frag-checked-seams-fix-architecture-verification-not-churn
provenance: Clean Code / Clean Architecture evaluation session (2026-08-13, Lars + Claude). A two-module swap demo (abstract port + default + override across files) ending in three runs: override live (42), default only (21), neither wired (KORU047 refuses the build)
ts: 2026-08-13
---

# Checked seams make Clean Architecture's central law hold by construction — and say nothing about Clean Code's churn

Interfaces are a symptom. An interface exists to permit *replacement* behind a
boundary the caller depends on. In C#/Java that works only if the
abstraction↔implementation mapping is hand-built (interface + concrete impl +
DI container + registration) — because the language cannot see the mapping, it
cannot verify it. So the architecture's one load-bearing law, *the boundary
holds*, is a convention guarded by attention, and attention decays: boundaries
rot, and the system "becomes" its worst-advertised layer. The barrage of
interfaces is not the disease; it is the scaffolding demanded by an unverifiable
mapping.

Koru's abstract tor is the same seam where the mapping is a **compiler-checked
fact**: one-to-one impl pairing (a second claim is refused), footgun-level
enforcement (an unfilled seam is `KORU047`, a build error — never a runtime
`No instance registered`), and the selection happens at compile time, so the
seam erases to nothing in the binary. The caller faces a port, not an
implementation, and the port is all there is — no interface/class pair to keep
in sync.

The scoped win, evidenced by the swap demo: with a default + override, the
override wins (42); remove the override, the default is the handler (21) with a
byte-identical caller; remove both, the compiler refuses to build and names the
port in prose. **This is the one thing Clean Architecture cannot buy: the
boundary does not merely degrade gracefully — it *holds*, e.g. its unwired
state is a build error, its memory cost is zero.**

The line in the sand, and the reason this belief is narrow: this verifies and
cheapens the *verification* half of Clean Architecture and says nothing about
Clean Code's *churn* failure. "Safe refactor" is not the same as "worthwhile
refactor": a compiler that tells you what a refactor broke lowers the *cost of
being wrong*, and can thereby lower the cost of being sloppy. The churn culture
is a people-problem; no proof obligation fixes a people-problem. The temptation
after a demo like this is to claim the grand thing ("we fixed Clean Code");
the honest claim is the narrow thing ("the boundary actually holds —
enforced").

Open: the `|js` host leg of the swap was never run end-to-end during the
session; the host-portability framing of the seam rests on the corpus's `|zig` /
`|js` proc facets and was asserted, not proven. And "build-time only" is a real
boundary — a genuinely runtime-selected strategy is a different mechanism, and
the claim here must not be stretched to cover it.

Related: [[frag-a-pass-that-can-remove-the-last-implementation-must-answer-to-the-check-that-required-one]]
(the enforcement is real enough to have had its own defect),
[[frag-a-wall-that-stands-down-program-wide-guards-nothing]]
(`KORU047`'s refusal can be stood down),
[[frag-a-portability-layer-is-the-thing-that-does-not-port]]
(the portability-shaped sibling).
