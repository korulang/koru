---
type: belief
id: frag-a-source-block-mints-declared-slots
provenance: session 2026-08-29 — std/kernel:reduce exposed it (the first Source-block to mint a variable); the general rule a Source-block DSL follows
ts: 2026-08-29
tags: [koru, source-block, dsl, metaprogramming, declarations, kernel]
---

# A `Source`-block DSL declares (mints) scoped, typed variables — and how it is handled is the strength (belief)

A `Source`-block is opaque text a transform interprets — a mini-DSL. Its power is
NOT that it accepts arbitrary content; it is HOW the block is handled. A transform
that interprets a `Source`-block may provide it bindings (the op's interface, e.g. a
kernel binding `k`), and the block may DECLARE names of its own: `name[type]` mints a
scoped, typed slot. The transform then decides what a declared slot is — a block-local
temporary, or an output that rides the enclosing continuation's binding (a handle).

The difference this makes is the difference between conjuring and declaring. A name
minted by bare use (the old `reduce { total_x += k.x }`, where the transform scanned
the text, guessed a name and a type, and let it escape) is magic: it existed because
you typed it under an operator, yet reached outside the block. A DECLARED slot
(`total_x[f64]`) is honest: you introduced it, you said its type, and the transform
decides its scope and whether it escapes. The escape is no less real — an inner
block reaching onto the enclosing continuation still reads unconventional — but it is
DELIBERATE and declared, not inferred.

This is likely the first place a `Source`-block mints new variables at all, and it is
the seed of the kernel DSL: a kernel op's body is a block over a binding (`k`), and
`name[type]` declares the slots that block introduces. The general rule, usable by any
Source-block transform: **a Source-block mini-DSL declares the names it introduces; a
name is never minted from use.**

What would correct this belief: if the declared-slot form were found to be a dead end
and some other mechanism (a signature-style output declaration, or implicit-with-
inference) turned out to be the right shape; or if a Source-block were shown to need
to mint names WITHOUT declaring them for a legitimate case.
