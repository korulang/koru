---
type: belief
id: frag-a-missing-helper-seam-is-often-a-wrongly-drawn-boundary
provenance: 2026-10-30 — std/quantity v2; the decimal core was duplicated across num.kz and quantity.kz for want of a cross-module Zig include, and the fix turned out to be deleting most of the Zig
ts: 2026-10-30
---

When two koru_std modules need the same host code, the reflex is to
invent a mechanism: an `~include` directive, a shared-zig namespace, a
link-this-module surface. Measured against [[frag-an-import-does-not-emit-a-module]],
none of those exist — emission is reachability-driven, host lines are
per-module, and `~import` is mark-resolution only.

The ruling that dissolved the problem: **a missing helper seam is
usually a wrongly drawn boundary.** The seam the language already has
is the tor itself. Zig stays only where marks are issued or consumed —
ingest, split, pack, unpack, the dim-vector algebra — and every law
becomes a Koru impl (`~name = ...`) that calls the other module's tors.
Crossing modules *through* the tor mechanism dedups the host code
without any new surface: std/quantity's arithmetic is ~200 lines of
Koru calls into std/num where it used to be a second copy of the whole
decimal core. Data crosses boundaries, logic does not.

Two mechanics the impls rely on, for the next session that forgets
them: record results (`-> {a, b}`) bind whole and hand out marked
fields (`f.mag` puns to leaf `mag`, flows to consuming params); and
`<mark>` on a param borrows state while `<!mark>` attaches the
obligation — a borrowed field cannot be discharged, so any field an
impl frees must arrive under `<!mark>`.

The check before reaching for a parser directive: can the consumer's
logic move below the boundary, so that what crosses is data? If yes,
the directive was the wrong tool. If no — the boundary itself is the
thing genuinely missing, and *then* it is a compiler rung.
