---
type: belief
id: frag-a-config-cycle-is-a-precedence-order
provenance: introduced while asking whether koru.json is necessary at all — the answer turned on whether a directive can be read by the pass that needs it
ts: 2026-07-30
---

# A configuration cycle is a precedence order, not a cycle (belief)

We believed configuration had to arrive from outside the program, because reading
it from inside is circular: to read a directive you must parse, and to parse the
imports you must already know how to resolve them. The circularity is real as
stated and false as a constraint. It is an *ordering*, and orderings have
solutions.

Two things make it one. First, a bootstrap rung that owes nothing to
configuration: `koruc` derives the standard library from its own executable path,
so `std` resolves before anything has been said about anything. Any mechanism
reachable through `std` is therefore reachable with zero config, which is the
whole of what "bootstrapping" needed to mean. Second, parse is a *single ordered
descent* — a declaration lexically above its first use is already in hand when
that use is read. What looked like a cycle was only a question of which line comes
first.

The fact that made it look fatal is the fact that makes it work. Parse and import
resolution are the same pass here: `parseImportDecl` resolves and then recursively
parses the imported file inline, with no separate resolution phase. Read as
"resolution needs config that only parsing can produce", that is a deadlock. Read
as "resolution happens statement by statement, in source order", it is a schedule.
The same property is the obstacle and the mechanism, depending only on whether you
model the pass as a phase or as a walk.

The cost is a genuine limit, and it is worth paying deliberately rather than
discovering later. A directive that acts *during* the descent cannot be harvested
*after* it, so it differs from every sibling declaration that waits for a
post-parse sweep: it is entry-file-only, and it must sit above its first use. A
declaration inside an imported file cannot retroactively change how that file was
found. This is not a defect to be engineered away — it is what makes the entry
file the single place a program describes itself, which was the point. But it does
mean a library cannot speak about its own dependencies through this door, and
that gap is real.

The corollary that generalises: **configuration stops being a thing handed to a
pass and becomes a thing the pass builds.** Concretely a `*const Config` loses its
const, and that one word is the whole architectural move. The broader shape is
that a compiler which can bootstrap one rung from its own identity can host, in
its own source language, anything downstream of that rung — the binary knows where
it lives, so the program never has to be told.

Choosing where such a directive lives is decided by *reachability*, not by
resemblance. Two mechanisms can have the same shape and the same job and still be
the wrong and right homes: the one that requires the author to write an import
line first is strictly worse than the one the compiler already injects at line
zero, because the second needs no bootstrap ceremony at all. Prefer the namespace
that is already present over the namespace that is merely appropriate.

The neighbouring mechanism looked like the obvious home and is not, for a reason
worth keeping: a pin is what distinguishes them. Vendoring means a frozen
third-party tree whose drift is a compile error; naming your own subdirectory
means live files you are editing, where drift is Tuesday. Giving the second to the
vendoring mechanism would produce a hash check over working files — a check
guaranteed to fire, which is the same as a check that means nothing. When two jobs
share a shape, look for the invariant one of them asserts; if the other cannot
honour it, they are not the same job.

Measurement kept arguing against the assumed shape of the problem. The config file
this replaced was 95% restatement of its own defaults — of 28 in the test corpus,
12 carried nothing but defaults, expressed as hand-counted `../` chains that break
silently if the directory moves. Corpus-wide, two aliases were in use and both were
defaults. Most of what a config file appears to provide can be provided by
knowing where the compiler is.

And two of its remaining jobs were not features at all but escape hatches from
rules enforced elsewhere: an alias existed to duck a 2-segment import depth cap,
and another existed because `../` is forbidden in import paths — legal, until now,
only in the config file. Relocating an escape hatch is not the same as removing
the need for one. Before moving a mechanism, check whether its users are there for
what it offers or for what it lets them avoid; the second kind are a signal about
a different rule.

That last distinction also settles a question that looks like inconsistency: the
`../` ban stays in imports and is allowed in the declaration. A use site is always
alias-relative, so the ban guards use; a declaration is where an escape out of the
tree gets written down once and read. The rule was never about the characters.

Open: whether the entry-file-only limit should be lifted for libraries, and if so
by what mechanism, is unsettled — a post-parse harvest cannot serve it, so it
would need a second rung rather than a widening of this one. Also unsettled is
whether the two parser rules whose escape hatch this was should survive contact
with the question, since a depth cap that authors routinely alias around is
enforcing paperwork rather than structure. Interpolating a *declared* compiler
flag into a path is in; interpolating an environment variable was ruled out on
purpose, because it would put the import graph in the invoking shell and undo the
self-containment the whole move exists to buy.

Pinned by: `110_027_paths_declared_in_source` (the alias moved out of a config
file that no longer exists in its directory), `110_028_paths_declared_in_pure_k`
(the same, tilde-free, so the surface is Koru's and not the host embedding's), and
`409`/`410`/`411` in `540_VALIDATION` for the refusals.
