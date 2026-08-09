---
type: belief
id: frag-a-representation-rule-must-not-eat-a-name
provenance: Corrected 2026-08-09. The 08-08 belief held that PARSE003 had removed the only way to name a single outcome and that Orisha's docs were therefore true and the language wrong. Both halves fail: the replacement spelling `-> { … }` existed and was tested, and what made it look absent was a separate parser defect (a braced produce in an arm read as an invocation) fixed the next morning in ddab3ed6. Lars reversed the ruling; b8570de5 is reverted, 210_190 now pins the refusal
ts: 2026-08-09
---

# A missing spelling is a claim to check, not a grievance to act on

**Repudiated:** *"the language had removed a word the docs depended on."* It had
not. An anonymous record return — `-> { status: string, body: string }` — was
already the way to declare one outcome with several fields, shipped in the
2026-08-03 migration and pinned across the AoC corpus and the phantom family. The
rule refusing `| response { … }` was not deleting the author's vocabulary; it was
routing to the spelling that existed. Its only real defect was that it said
`-> <type>` and made the author work out the shape, which is now fixed by naming
the concrete record in the diagnostic.

**What produced the false belief is the part worth keeping.** The substitute
*was* tried, and it garbled — so the conclusion "there is no substitute" felt
measured rather than assumed. The garbling was a parser bug with its own life:
`-> name { … }` in a branch arm was read as an invocation, on ordinary
two-branch tors as much as on this shape. One broken probe of the alternative
was treated as proof the alternative did not exist, and a language change was
argued from it. The alternative was fine; the road to it had a hole, and the
hole was the work.

So the general shape is not "a representation rule must not eat a name." It is:

> **When a rule appears to have removed surface, the first question is not what
> the rule cost — it is whether the surface it points at actually works.** A
> failed probe of the replacement is evidence about the *compiler*, and reads
> exactly like evidence about the *language*.

The distinction the old fragment drew — a constraint on how something is
REPRESENTED versus how it may be SPOKEN — survives as a question worth asking,
but it was not what was happening here, and asking it first is what made a
compiler defect look like a design flaw. Consumer docs going stale is the
ordinary outcome of a migration; treating "the docs still say `response`" as
proof the language was wrong inverted the burden.

**Two things the old fragment recorded as costs are better read as prices, and
they were the argument against the feature.** Five separate emitters each had to
learn that one name means *no wrapper*, and four of the five looked like the
right site before instrumenting proved otherwise — see
[[frag-a-name-mangling-dispatcher-assumes-a-parity-nobody-maintains]]. A surface
that needs teaching in five places is a surface carrying a second construction
path for a shape that already had one. That is not an implementation note to
absorb; it is the quote coming back, and it was for a synonym: a tor's own name
already says what it produces.
