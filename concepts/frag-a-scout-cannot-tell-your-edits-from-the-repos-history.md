---
type: belief
id: frag-a-scout-cannot-tell-your-edits-from-the-repos-history
provenance: cluster D_template_variant — a scout asked whether test-local template constructs were the intended shape cited a sentence the SAME session had written hours earlier, dated it to the file's creation, and made it its headline
ts: 2026-08-06
tags: [subagents, evidence, method]
---

# A subagent reading the working tree cannot tell your edits from the repo's history — so "the tree already said this" needs a pre-session commit, not a grep (belief)

A read-only scout was sent to settle a real question: are the per-call template
constructs declared inside test files the intended test-design shape, or accretion
that belongs in `koru_std`? Good question, cleanly scoped, read-only, `file:line`
citations demanded.

It came back with a headline built on a sentence in `400_093`'s header —
*"a per-call template's variants are the obligation of whoever DECLARES the
construct, and this test is the declarer"* — reported as fixture doctrine dating
to the file's creation, and offered as evidence that *predates* the JS-parity work
under review. **That sentence was written by the parent session, that same day, in
an uncommitted-at-the-time edit.** `git show <base>:…/400_093/input.kz` has no such
line. The scout had cited the reviewer's own opinion back to the reviewer as
independent corroboration, and it happened to be the load-bearing citation.

**Nothing the scout did was wrong.** It read the working tree, which is what a
scout reads. At read time a sentence written ninety minutes ago and a sentence
written in May are the same bytes in the same file with the same mtime-irrelevance.
A subagent starts blank: it does not know which turns it is downstream of, cannot
see the parent's diff, and has no reason to suspect that the tree it was pointed at
is partly the parent's draft. **The failure is in the brief, not the reader.**

**The guard is mechanical and cheap:** any claim of the form "the tree already
said X" must be cited against a commit that predates the session's first edit. Pass
the base SHA into the brief and require `git show <base>:<path>` for every
historical claim. That is one line of instruction and it converts an
unfalsifiable impression into a checkable fact.

**The general shape is worse than the specific bug, which is why this is written
down.** Delegation is normally a defence against one's own bias: a fresh reader
with no stake re-derives the answer. That defence inverts the moment the artifact
under review is *inside the corpus being searched*. The scout is not an
independent witness then; it is a mirror with a citation format, and a citation
format is exactly what makes a mirror persuasive. The more scrupulous the scout's
`file:line` discipline, the more credible the circular claim looks.

Two practices follow, and the second is the one that generalises:

- **Prose you author into a searched corpus becomes evidence against you.** This
  is a second, independent reason to keep doctrine out of test headers (the first
  being the repo's own standard that a test comment states what the test *pins*).
  A header that argues a general rule will be found and cited as though the
  fixture had always believed it. Doctrine belongs in `concepts/`, where the
  frontmatter carries a date and a provenance and cannot masquerade as fixture age.
- **When you delegate a question about the tree, name what you have changed.** The
  parent knows its own diff; the subagent cannot. Withholding it is not neutrality,
  it is handing over a contaminated sample and asking for an unbiased reading.

Caught here only because the cited sentence sounded familiar. That is not a
control — it is luck, and it does not scale to a citation the parent merely
*agrees* with rather than recognises verbatim. Open question: whether the same
contamination has quietly shaped earlier conclusions in this repo's agent-authored
prose, which nobody has looked for and which would be found the same way — diff
every agent-era concept's cited evidence against the commit that preceded the
session that wrote it.
