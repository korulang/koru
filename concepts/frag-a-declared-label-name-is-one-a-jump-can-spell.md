---
type: belief
id: frag-a-declared-label-name-is-one-a-jump-can-spell
provenance: tightening-016 probe of label-declaration argument records — `@done(r: {a: 1, a: 2})` compiled clean, minting a label no jump can name
ts: 2026-10-11
tags: [koru, labels, parser, diagnostics, declaration-vs-use]
---

# A declared label name must be one a jump can spell; argument text on a declaration is a malformed name, not a payload (belief)

Label declarations — `~@name`, `~#name`, `~#name event(...)`, and the `.k`
spelling `@name` — used to take the rest of the line as the name verbatim.
`@done(r: {a: 1, a: 2})` parsed and compiled clean, registering a label
literally named `done(r: {a: 1, a: 2})`. No `@name` jump can spell that —
the jump's `extractLabel` takes identifier characters only — so the
declaration minted a label unreachable by construction.

Worse, the misattribution was built in: a following `@done` jump (with its
own, legal, argument list) then failed as "unknown label" — the *jump* took
the blame for the *declaration's* fault, the inversion
frag-a-reproducible-failure-localises-the-symptom-not-the-defect warns
about: the error surfaced where the invariant was checked, not where it was
broken.

## The rule

A label declaration's name is an identifier — the same grammar the jump
spelling accepts. Anything else after the sigil is malformed syntax, refused
at the declaration with `PARSE003`, before any jump can be blamed for it.
Arguments belong on the jump (`|> @done(r: 1)`), never on the anchor;
the declaration is not a payload-bearing site. This is the declaration-side
sibling of the rule that a jump's argument must be a spelled `name: value`
pair — both ends now refuse the other's syntax.

## The generalisation the Open section predicted (landed)

The census this file's Open section asked for ran on the other free-text
declaration names, and the hole was the same shape everywhere it was measured:
`tor evil(x)`, `~proc evil(x)|zig`, `~sub(x) = …`, and `tor m:speech` all
registered names no caller could spell, and the use sites ate "unknown tor"
/ "proc without matching event" for text they never wrote. The rule is now
one wall — `rejectUnspellableDeclName` gates every decl path the tor, proc,
and subflow-impl parsers produce (210_303–306). The legal names it must
never refuse: kebab segments, the transform glob `*`, an `[…]` marker tail
(`close[!]`, `name[T:u32]`), and the `m:name` qualifier on the impl side
(`~proc m:name` serves a contract where it lives — on a `tor` decl it is the
unspellable mirror, since a tor is declared in its own module).

## Open

- The declaration sites are now all gated (label, tor, proc, subflow impl).
  The transform side measured the same way once: `std/store:new(evil(x))`
  pasted its name argument verbatim into `const __KoruStoreT_<name>` and Zig
  died on a symbol the author never wrote — gated with the target's
  identifier grammar at the transform (690_350, KORU161). Note the gate is
  stricter than Koru's kebab: the name lands inside a Zig decl, so `-` is
  refused too — a kebab store name would need mangle-on-write, which is
  frag-every-name-writing-site-must-mangle's contract, not this one's.
  Other transform-declared names (`std/grid:new`, capture names, `proto`
  heads) are the still-open cells.
