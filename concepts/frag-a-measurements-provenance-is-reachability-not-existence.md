---
type: belief
id: frag-a-measurements-provenance-is-reachability-not-existence
provenance: 2026-08-09 — the unikernel RAM floor. The bisection was real, the commit recording it was real and detailed, and it sat on `worktree-produce-position`, unreachable from main. Main's BUILD.md said "not measured" for a day while a blog draft led with the number and cited that file as its grounding
ts: 2026-08-09
---

# A number's provenance is that its commit is REACHABLE, not that it exists

Citing a measurement means pointing at where it was taken. The pointer people
actually write is a commit SHA, and a SHA resolves whether or not the commit is
an ancestor of anything that ships. So a citation can be simultaneously honest,
checkable, and useless: the reader who follows it to the file on main finds the
opposite claim, and the reader who trusts the SHA finds a real bisection with a
real error trace.

Here main said, in the very file a draft named as its grounding, *"RAM floor is
not measured here — 64 MB was given and not probed downward"*, while the draft's
opening sentence quoted a floor. Nothing was fabricated. The branch simply never
merged, and every downstream retelling inherited a number the repo denied.

**The failure is not carelessness about merging — it is that "I have a commit
for that" FEELS like provenance and is not.** The check is one command and
nobody runs it, because the SHA resolving is already a small green light:

    git merge-base --is-ancestor <sha> HEAD

**And the damage compounds downstream, in a specific way.** Once a number is
loose from its file, it travels next to *other* numbers from the same table and
gets welded to the wrong one. The same week, this floor was retold as "a 164 KB
image that boots in 6 MB" — the 164 KB build is a different image one directory
over with a 2 MB floor, and the two figures sit three lines apart in one table.
No such image exists. That retelling even shipped a falsification recipe with
it, which is what a confident number looks like when it has drifted off its
source.

So the rule has two halves and the second is the one that bites: **cite the file
that ships, not the commit that measured; and when a table holds several builds'
numbers, a number quoted without its build is already wrong.**

**What would correct this:** a check that reads every measurement cited in a
published artifact and fails when the cited commit is not an ancestor of the
deployed ref. Then reachability stops being a discipline and becomes a wall, and
this fragment describes a hazard the machine has absorbed. Until then, the
cheapest honest habit is to re-derive a number from the file on main before
repeating it — which is also how this one was caught, by rebuilding the image
and finding the artifacts byte-exact.
