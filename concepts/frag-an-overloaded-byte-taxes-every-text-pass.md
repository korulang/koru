---
type: belief
id: frag-an-overloaded-byte-taxes-every-text-pass
provenance: the ECS benchmark's bounce arm wrote `-d.vx * 0.8`; the store's row rewriter read the minus as the interior of a kebab name and emitted the binding verbatim into the host
ts: 2026-08-03
---

# A syntax choice that overloads a byte taxes every text-level pass (belief)

Koru's identifiers are kebab-case, so `-` is an identifier byte: `set-scenario`
is one name. It is also subtraction, and negation. That is a surface decision
that reads as purely cosmetic and is not: it makes ONE byte mean two things,
and every pass that looks at program text has to disambiguate it.

They do not. The universal token-boundary test in a text rewriter is *"the byte
before is not an identifier character"*, and with `-` in the identifier
alphabet that test refuses to see a token that a unary minus abuts. `-r.v`
reads as the tail of a name like `foo-r`, so nothing is rewritten and the row
binding travels verbatim into generated host source, where it does not exist.
The author gets a host error naming their own Koru binding, about a program
that is correct Koru (690_244 pins it).

The disambiguation is local and total: **a `-` belongs to an identifier only
when it sits BETWEEN two identifier characters.** It is three lines. The cost
was never the rule — it was that the rule had nowhere to live.

## Why nobody hit it for as long as the store has existed

Because `- r.v`, with a space, works, and prose-shaped code has spaces in it. A
compiler author writing a test writes `a - b`. It takes a *reflection* —
`-d.vx * 0.8`, the plainest spelling of a bounce — to abut the two, and the
corpus had no reason to contain one. This is the corpus-idiom failure
(`frag-a-corpus-exercises-its-authors-idioms`) with an unusually thin trigger:
not a different construct, a different amount of whitespace. Whitespace carries
no meaning inside a Koru expression, which is exactly why an author cannot
find this and cannot be expected to suspect it.

## The tax is per-site, and nobody is counting the sites

There is no shared notion of "identifier byte" in this compiler. Counted while
fixing this: twelve private `isIdentChar` definitions across the tree, five of
them hyphen-aware; `std/store` alone holds seven independent left-boundary
checks behind seven local predicates with three different names. Every one is a
place to get the same rule wrong, and the differing names are why a grep for
one spelling finds only some of them.

That makes this the same shape as `frag-a-fix-lands-in-one-lowering-path`'s
N-scanners case, arriving from the other direction: there the duplication was
discovered by a bug and counted afterwards; here the duplication was *created*
by a syntax decision that never named its obligation.

## What follows

- **A syntax decision that overloads a byte incurs a debt on every text-level
  pass, and the debt should be discharged as ONE shared predicate at the moment
  the syntax lands.** Kebab-case shipped as a lexer change. Nothing said "and
  now every rewriter's boundary test is wrong"; nothing could, because there was
  no list of rewriters.
- **Prefer counting the predicate, not the bug.** "How many definitions of
  identifier-byte does this compiler have?" is a one-line question that would
  have exposed this class years before any program tripped it, and it stays
  answerable as the tree grows.
- **A whitespace-sensitive failure in a whitespace-insensitive language is
  unfindable from the author's chair.** When a construct works spaced and fails
  abutted, that is never a program bug and always a lexical one; it belongs in
  the compiler's own suspicion list, not in a style guide.

## Open

Whether the transform layer should be manipulating program TEXT at all. Every
one of these rewriters re-derives lexical rules the lexer already owns, on
strings, after parsing — which is where the whole class comes from. Rewriting
the AST instead would make the boundary question disappear rather than be
answered correctly in a dozen places. That is a much larger change than the
shared predicate, and the predicate is the mitigation, not the ambition.
