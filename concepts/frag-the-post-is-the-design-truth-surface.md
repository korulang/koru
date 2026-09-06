---
type: belief
id: frag-the-post-is-the-design-truth-surface
provenance: Lars-ruled 2026-09-06, after the store:set landing diverged from the design its post described and a session argued the post was "just documentation"
ts: 2026-09-06
---

# The blog post is the design truth-surface; a diverging implementation is the defect (belief)

A korulang.org blog post announcing a landed feature **IS the design** — a
truth-reporting surface. When the implementation diverges from it, the
implementation is the lie, and the fix lands in the compiler. The post is
never "documentation of the implementation" to be edited until it matches;
it re-grounds in the same pass as a surface change, never ahead of it.

The failure mode this rules against: a session finding a mismatch between
post and implementation and resolving it by recasting the post as
subordinate documentation — legitimizing the divergence and forcing the
designer to re-explain their own design. Never question the design; verify
and report the implementation faithfully.

Boundary: this governs the authored design surface (the post). It does not
say prose comments override the compiler — a stale header comment is still
a comment, and the suite still wins over incidental prose. The post states
intent; the tests pin behavior; where the implementation disagrees with
both, the implementation is the defect.
