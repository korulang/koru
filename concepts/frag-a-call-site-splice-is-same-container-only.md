---
type: belief
id: frag-a-call-site-splice-is-same-container-only
provenance: 2026-08-20 — koru-libs/asteroids: sim:thrust-dx referencing SHIP_THRUST from an imported const{}; the caller's emitted flow carried the bare name to a `use of undeclared identifier`
ts: 2026-08-20
---

# A call-site splice is same-container-only; the module boundary is a call, not a paste

The emitter inlines an immediate-impl body into the *caller's* emitted flow: the
caller gets a `blk:` carrying the body text, bare names and all. That splice is
sound wherever caller and impl land in the **same emitted container** — the
entry file, where `const {}` and every caller share one struct.

Past a **module boundary** it silently corrupts. The module's `const{}` block is
emitted inside that module's own struct; the caller's flow only received the body
text, so it reads bare names that exist in a container that is *not* its scope —
`use of undeclared identifier 'SHIP_THRUST'`, a stack-backed frame reading names
that were never there.

**The rule: across a module boundary it is a call, not a paste.** Call
`<module>.event.handler(.{ args })` — the handler lives in the module's struct
where its consts resolve — and keep the zero-cost splice for same-module calls.
That is also exactly what `import` already means: qualified = reach across and
call; unqualified = same scope, inline.

## Wrong-candidate

A future emitter could keep splicing and *qualify every bare name* to the
declaring module's container (`<mod>.SHIP_THRUST`). The rule says don't — the
module is where a library's scope lives, and a paste plus manual re-qualification
is how scope-leak bugs like this one are born — but a proof that the qualification
is total would `correct` this belief.

## Family

The emission-side twin of [[frag-a-parse-time-remap-is-entry-file-only]]: the
same shape — a convenience that is *entry-file-only by construction* and fails
*silently* when the author reaches across modules. The parse-time copy consults a
registry that isn't loaded yet; this one splices a container's scope into a
foreign one. Both name the same boundary discipline.

## Pin

Regression 110_031 `(const in imported module, cross-module call through the
handler)`.