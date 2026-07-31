---
type: belief
id: frag-an-ecosystem-alias-belongs-in-the-toolchain-not-every-config
provenance: Lars, 2026-07-31 — "we were supposed to remove koru.json, not burden ALL PROGRAMS with paths in the source code"
ts: 2026-07-31
---

# A name that denotes a known location belongs in the toolchain's defaults; only a claim about the local machine belongs in a program's config (belief)

`import koru/vaxis` failed with `unknown import alias: 'koru'` in any program
that had not been handed a config file naming a directory. Nine of the ten
examples in koru-examples carried a `koru.json` whose entire content was that one
alias, all pointing at the same place. The tenth had no config file, so it could
not compile at all.

`std` never had this problem. It resolves off the koruc executable and needs no
config anywhere, so no program has ever had to say where the standard library is.
`koru` is the same kind of name and now has the same standing.

## The test for whether something should be a default

Ask what the name *denotes*.

- **A known location** — the standard library, the ecosystem's libraries. The
  program is naming a thing the toolchain is responsible for knowing where to
  find. This belongs in defaults.
- **A claim about this machine or this project** — where *my* modules live, which
  directory a build variant reads from. The program is asserting something only
  it knows. This belongs in the program's own declaration.

`koru/vaxis` is the first. Treating it as the second is what produced nine config
files that all said the same sentence, maintained by everyone and owned by
nobody. Boilerplate repeated identically across consumers is the symptom: if
every user of a name writes the same line, the line belongs upstream of them.

## Moving boilerplate is not removing it

`std/compiler:paths` lets a program declare its own aliases in source, and the
hint on the failure was duly updated from "add it to koru.json" to "declare it in
the entry file". Nothing about the burden changed — the same sentence, in a
different file, still written by every consumer. See
[[frag-a-tool-reports-what-it-did-not-what-it-skipped]] for the adjacent habit:
the diagnostic improved while the defect stayed.

`std/compiler:paths` remains right for what it is good at, a program's own
private aliases. It is the wrong answer to "where does the ecosystem live",
because that is not a question a program should be asked.

## A probe is not a fallback

The default resolves through two candidates in order: vendored beside `koru_std`
for an installed toolchain, then a sibling checkout for a development tree. That
is deliberately not the banned fallback pattern. Both candidates are the *same
libraries* in different install layouts, so neither substitutes for the other's
content, and when neither exists the import fails loudly as "module not found"
rather than resolving to something else. The distinction that matters: a probe
locates one thing that exists in one of several places; a fallback supplies a
different thing when the real one is missing.

## Open

`libs` is a second alias for the same directory, declared by six examples and
used by exactly one import. It is deliberately NOT defaulted — migrating that one
site would let every remaining `koru.json` be deleted, which is the actual goal.
Whether the ecosystem should ever ship two names for one location is unexamined.
