---
type: belief
id: frag-zig-keyword-escape-per-site
provenance: introduced with the 320_132 pin — self-loop weaver leaks unescaped 'else' binder, surfaced by the fannkuch-redux port in koru-benchmarks suites/plb
ts: 2026-07-16
---

# Zig-keyword escaping is per-site in the emitter — every new emission path is a fresh hole

Koru branch names (`else`, `error`, potentially any user branch) share an
identifier space with Zig keywords the moment they are lowered to binder
names in emitted Zig. We believed the escape discipline covered this
uniformly — io.kz's `appendEscapedPath` handles dotted paths in
interpolations, and the subflow weaver quotes its branch captures
(`.@"else" => |@"else"|`). The 320_132 pin
(`320_132_else_arm_keyword_escape_selfloop`) contradicts that: the
self-loop weaver's binder *discard* emits the raw keyword (`_ = &else;`),
proving escaping is a set of independent per-site habits, not a
centralized guarantee.

The belief this leaves us with: **any emitter code that turns a Koru-side
name into a Zig identifier must go through one shared escaping seam** —
per-site escaping structurally regenerates this bug class every time a
new emission path is written. Until that seam exists, a new lowering path
touching branch names is guilty until proven escaped.

Open question (for the fix discussion): whether the seam is a
`zigIdent(name)` helper every emission site calls, or the weaver naming
binders away from user-visible names entirely (e.g. `__koru_arm_0`), which
would dissolve the collision space instead of escaping around it.
