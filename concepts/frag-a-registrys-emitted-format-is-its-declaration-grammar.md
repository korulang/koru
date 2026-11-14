---
type: belief
id: frag-a-registrys-emitted-format-is-its-declaration-grammar
provenance: rel-decls commit on quantity-numbers — batch declaration parsing the emitted tail
ts: 2026-11-14
tags: [koru, sym, rel, registry, canonical-text, dsl]
---

# A registry's emitted format is its declaration grammar — the batch tor is a re-parse, not a new DSL (belief)

`rel:v1;sin=g(cos);cos=(-1e0*g(sin))` is what `rel-seed`/`rel-law` emit
after threading. It is also a complete *declaration*: every entry is
`name` or `name=law`, `;`-separated — exactly the two-phase order the
threaded path imposes (all names exist before any law is parsed, so
cyclic pairs and forward references both resolve). `rel-decls(reg, src)`
takes that grammar as input — optionally `rel:v1`-prefixed — and the
consequence is free composition: registry text concatenates into
registry text, and `rel-decls(r, otherRegistryText)` is a merge.

The ruling generalizes beyond rel: when a value's canonical string form
enumerates its construction steps (each `;`-entry is one declaration),
the format IS the DSL — the batch tor needs no separate block grammar,
no keyword, no transform. Designing the emitted format is designing the
declaration language; a format that can't be re-declared is a format
that lost information.

The discipline is the same two-phase everywhere: a declaration block
collects its complete name set before any law parses — batch and
threaded semantics agree by construction, not by parallel convention.
Atomicity falls out of staging: the block builds under an arena and
emits only on success, so a `dup`/`full`/`unknown-generator`/`bad`
anywhere voids the whole block — one arm set, not one per entry.

Pairs with [[frag-a-phantom-can-only-promise-what-a-producer-can-prove]]
(registry text stays plain `string` — validity is still parse-under-ctx)
and the trusted-literal frag (the *authored* lane keeps `lit`-style
capture; a registry block is data, not provenance — `src` is a plain
composable string by design).
