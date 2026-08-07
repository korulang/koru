---
type: belief
id: frag-the-safe-koru-identifier-surface-is-smaller-than-the-language-says
provenance: two independent contestants in the 2026-08-06 unikraft wave hit different halves of it; both halves reproduced minimally and pinned as 230_017 and 230_018
ts: 2026-08-07
---

# Koru identifiers are written into the emitted Zig unescaped, so the set of names an author may safely use is smaller than Koru's grammar admits — and nothing reports the boundary (belief)

Koru's identifier rules are its own. The emitter's are Zig's. Where a Koru name
reaches emitted Zig as a bare token — a tor parameter, a continuation binding —
the author is silently subject to *both*, and only the first is documented,
checked, or diagnosable.

## The two halves, which fail differently

Both pass `koruc --check`. Both are refused later, by the Zig compiler, quoting
generated code and naming a line the author never wrote.

- **Zig keywords.** A parameter named `align` emits `const align = …`, which is a
  Zig syntax error. Pinned as `230_017`; the diagnostic is `expected ';' after
  statement`.
- **Zig primitive types.** A binding named `u1` emits a declaration that fails as
  `name shadows primitive 'u1'`. Pinned as `230_018`. The whole `u*`/`i*` family
  plus `bool`, `void`, `type`, `anyopaque` are all legal Koru identifiers.

They are one disease and two fixes: escaping at the emission site (`@"align"`)
handles the keyword half, and the primitive half needs the same treatment at a
different site, since a shadowed primitive is not a syntax error. Filed as two
pins on purpose — either can be fixed without the other, and a single pin would
go green on half a fix.

## Why this is not "just rename it"

A renamed surface is a route-around, and this repo bans those for a reason that
applies exactly here: **the author cannot know the boundary.** There is no list,
no diagnostic, and no failing check until a backend the author may never have
read rejects code they did not write. Two contestants hit two different halves in
one night without either being careless — one was naming an alignment parameter
`align`, which is the only honest name for it.

The containment when you are blocked and cannot wait for a fix is the same as for
[[frag-a-host-line-local-degrades-tor-input-binding-to-textual-substitution]]:
move whatever is incidental, never the designed surface. An alignment parameter
called `alignment` is a small loss; a state or a tor renamed to suit an emitter
bug is a design corrupted by a backend, and it hides the defect from the next
reader.

## What follows

- **The rule generalises past these two lists.** Any name the emitter passes
  through unescaped inherits every constraint of the target language. As the JS
  target grows, it inherits JavaScript's reserved words too — and its list is
  different, so a name that is safe today may be unsafe on another facet. The
  durable fix is escaping at every emission site, not enumerating a blocklist.
- **`--check` passing is not evidence the program will build.** That is worth
  holding separately from these two pins: `--check` is a shape check, and every
  defect in this family lives strictly after it.
