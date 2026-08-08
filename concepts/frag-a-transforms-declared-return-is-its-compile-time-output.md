---
type: belief
id: frag-a-transforms-declared-return-is-its-compile-time-output
provenance: KORU094 read `orisha:router`'s `-> SiteResult` as the value its call site produces at runtime, and refused `~orisha:handler = orisha:router(req)` — the documented shape of every Orisha server. The `want` side of the same comparison was already exempt. Fixed 2026-08-08
ts: 2026-08-08
---

# A transform's declared return is its compile-time output, not its site's runtime value

A `[comptime|transform]` tor returns a `SiteResult`: an instruction to rewrite
the call site. It is consumed by the compiler and never exists when the program
runs. What the site produces at runtime is whatever the *replacement* produces —
and no declaration anywhere states that, because the replacement is computed.

So a declared return type means two different things depending on the kind of
tor that carries it, and any check that reads `return_type` has to ask which. The
flow-terminus wall asked on one side of its comparison and not the other: an
enclosing flow declaring `-> SiteResult` was exempt (it constructs its own), but
a chain whose last STEP was a transform got its `SiteResult` compared as an
ordinary runtime type. The result was a refusal quoting a type the program never
has, against the documented shape of every server built on the framework.

The knowledge was not missing. `EventInfo.return_type`'s own doc comment says a
transform "lands as `-> SiteResult`; its RUNTIME value is a result struct the
caller must field-access". **The fact was written down next to the field and
still not applied at the one site that most needed it** — which is the ordinary
way a fact fails to be load-bearing: comments travel with declarations, checks
travel with rules, and nothing makes them meet.

The general form: **when one field carries two meanings selected by a kind tag,
every reader is a place the distinction can be dropped.** Either the two meanings
get two fields, or every read goes through an accessor that demands the kind.
Documenting the distinction only makes the next reader who skips it feel
justified.

Note what the fix does NOT do: it does not infer the replacement's type. It
declines to check, because at that point in the pipeline there is nothing to
check against. **A wall that cannot see its subject should stand down, not
guess** — the alternative is a confident sentence about a type the program never
has, which is what this was.

Related: [[frag-a-diagnostics-hint-is-a-claim-not-a-tested-path]] — a diagnostic
asserting something about the language that nothing exercised.
