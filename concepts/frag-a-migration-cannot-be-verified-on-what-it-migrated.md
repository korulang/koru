---
type: belief
id: frag-a-migration-cannot-be-verified-on-what-it-migrated
provenance: the RULING -> NEEDS_RULING rename, 2026-08-07 — all 11 markers moved, both consumers were updated, the rename was verified against those 11 and was complete for exactly them; the allowlist that admits the name was not updated, so the twelfth marker written that day silently never entered the repo
ts: 2026-08-07
---

# A migration verified on the things it migrated has sampled the immune population (belief)

Rename a marker across a repo and the honest-looking check is: did all N move,
and do the consumers still find them? That check passes and means less than it
appears to, because **the N you moved are frequently immune to the failure you
are looking for.**

The instance: markers were renamed with `git mv`, so all of them stayed tracked
— and `.gitignore` only governs *untracked* files. The allowlist that admits the
marker's name still listed the old spelling. Every existing marker kept working
forever; the next one written was silently never added to the repo. The
population that could demonstrate the bug had exactly one member and it did not
exist yet.

The general shape is worth more than the instance. Anywhere admission is
governed by a list AND membership is cached — git's index, a plugin registry, a
seeded database, an allowlisted config — **the already-admitted are held in by
the cache, not by the list.** Editing the list wrong is therefore invisible in
proportion to how much history you have. A mature system is the most misleading
place to run this check.

So the test of a rename is never the corpus. It is: write one new thing with the
new name, from a clean state, and see whether it arrives.

## What made it silent rather than wrong

Nothing failed. No red, no diagnostic, no conflict — the file sat in the working
tree looking committed. The tool that lists the markers reads the working tree,
so the author who wrote the twelfth saw twelve and everyone else saw eleven. An
absent file is not a stale one, so the staleness wall had nothing to say either.
Divergence between a working tree and a repo is invisible to every check that
runs in the working tree, which is all of them.

Related: [[frag-evidence-must-count-the-same-thing-the-verdict-does]] — a
sibling failure of measurement, with the other cause. There two surfaces
computed one word differently and the operator believed the looser. Here one
surface computed correctly, over the wrong population.
