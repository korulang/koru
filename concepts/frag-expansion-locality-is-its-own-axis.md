---
type: belief
id: frag-expansion-locality-is-its-own-axis
provenance: session 2026-07-25 (Lars + Claude) — splitting koru-examples' gallery into modules
ts: 2026-07-25
tags: [modules, transforms, store, vaxis, composition]
---

# Expansion locality is an axis of its own — and it decides what crosses a module boundary

**Lars's frame:** writing a Koru library is ~70% conventional library authoring
and ~30% compiler plugin. That split is not aesthetic. It is *exactly* the
composition boundary, and every module-boundary failure we have found sits on it.

| | crosses a module boundary |
|---|---|
| ordinary value tors | **yes** (koru-examples/ledger, gallery/content) |
| local-expansion transforms — `std/template:define` | **yes** |
| keyword tors — `cond`, `if` | **yes**, since 50182722 (110_021) |
| whole-program-synthesis transforms — vaxis pump attach, store ENVELOPE writes | **no** |
| `std/store` single-field read/write | **yes**, since d887b5ae (110_022/690_078) |

## The predictive claim, and its confirmation

The frame was derived from `std/store` failing, then used to predict that
`koru/vaxis`'s pump attach would fail the same way — it is the other transform
that synthesizes across a whole program (splicing `!` arms into `run`'s `__H`).
It does, with a matching signature:

    koru/vaxis(demo)  from a module -> unknown tor 'app.arms:koru/vaxis'
    std/store:stored  from a module -> unknown tor 'ops:__store_write_s'

Both compile inline in the entry. The frame predicted a bug before anyone looked
at it, which is the only real test of a frame. Pinned: 110_022 (store, both
directions — a module read leaks raw Zig, a module write leaks the synthesized
tor name). The vaxis case is deliberately NOT separately pinned: one root cause,
one pin.

## Why it breaks — the 30% has no declared surface

The conventional 70% announces itself with `pub`: a contract the resolver honors
and a diagnostic can cite. The plugin 30% announces nothing. `std/store` mints
`__koru_store_s` and `__store_write_s` and rewrites references program-wide, and
nowhere states that those symbols exist or what scope their identity carries. So
there is nothing to check against and nothing to teach with — the failure
surfaces as `unknown tor 'ops:__store_write_s'`, an internal name leaking at a
user who never wrote it.

Half the language is disciplined by a declaration. The other half rewrites the
whole program and is disciplined by nothing.

## The move, precedented

[[frag-expression-source-are-strings-not-comptime]] took *representation* and
*timing*, declared them orthogonal, and forbade inferring one from the other —
and the damage it repaired was precisely the damage of that conflation. The same
move is available here: **expansion locality and comptime-ness are two axes, and
today they are one.** Being a transform tells you nothing about whether you
expand in place or synthesize across the program. `std/template` and `std/store`
are both `[comptime|transform]`, behave completely differently at a module
boundary, and nothing in either declaration distinguishes them.

Make locality declared and three things follow: the resolver knows which
synthesized symbols carry program-global identity; the diagnostic can say "this
store was declared in the entry and its accessors do not cross" instead of
leaking `__store_write_s`; and a library author learns which half of the 70/30
they are writing in.

## The consequence worth remembering

"We are not very good at using our bespoke libraries" is the wrong diagnosis.
`std/store` and `std/template` look identical from the outside and one of them
cannot be used from a second file. Nothing tells you which is which except
importing it and watching it break. That is a missing declaration, not a skill
gap.

## Moving target — verified 2026-07-25, same night

The boundary is being actively pushed and this fragment was stale within the
hour of writing. 110_021 landed (keyword tors cross), then d887b5ae landed
(single-field store reads and writes cross). Re-tested after each: the gallery
split got one wall further each time.

What still does not cross, SHOWN after d887b5ae:
- **multi-field store writes.** `stored { s.a: 7, s.b: 9 }` from a module ->
  `unknown tor 'ops:__store_envwrite_s'`, while the single-field form in the
  same position prints `a=1 b=0`. The fix reached `__store_write_*` and not
  `__store_envwrite_*`.
- **vaxis pump attach.** `koru/vaxis(demo)` from a module ->
  `unknown tor 'app.arms:koru/vaxis'`.

So the FRAME holds — whole-program synthesis is still the thing that does not
compose — but the frontier moves per fix, and the honest form of this belief is
a direction plus a dated probe, never a fixed list. koru-examples' gallery is
the standing acceptance test: split its key vocabulary into `keys/index.k` and
whatever it dies on is the next wall.
