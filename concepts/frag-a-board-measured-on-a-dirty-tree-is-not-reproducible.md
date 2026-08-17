---
type: belief
id: frag-a-board-measured-on-a-dirty-tree-is-not-reproducible
provenance: introduced 2026-08-01 — two consecutive ceremonies published a number and an attribution that could not be derived from the commit they were published under
ts: 2026-08-01
---

# A published board is a claim about a COMMIT; measuring it against a working tree quietly breaks that (belief)

The board is the project's headline artifact, and its whole value is that it is
**checkable**: anyone can take the commit it names, build it, and get the number
back. A run measured against a working tree with uncommitted changes still
prints a number and still stamps a `gitCommit`, and that number is not derivable
from that commit by anyone, ever. Nothing in the pipeline notices — the harness
has no opinion about `git status`, the snapshot records the SHA it was told, and
the site renders whatever it is handed.

The instance, twice in one day. A full board was run while another session had
~90 uncommitted lines in `koru_std/store.kz`. It published **1281/1445** under
`c0d6bc05`; the true figure at that commit was 1280, and the difference was a
test only the uncommitted work made pass. The same run then credited that green
to an unrelated `clonePath` fix in the same publish — a second claim that the
commit cannot support.

**Two distinct failures, and the second is the worse one.** The count being off
by one is embarrassing and self-correcting. The *attribution* is not: it says a
particular change did a particular thing, it ends up in a commit message, a
Discord post and a status page, and it is what the next reader believes. A wrong
number invites a recount. A wrong cause invites nothing, because it explains
everything it needs to.

**Why the discipline is hard here specifically.** Concurrent sessions in one repo
are normal in this project and mostly harmless, and the person publishing usually
did not make the edit and has no way to know what it is. So "check your tree
before publishing" is not a personal-diligence instruction; it is a claim the
ARTIFACT has to carry. The check is trivial and mechanical: a board destined for
publication is measured on a clean tree, or its snapshot records that it was not.

**The corollary that is easy to miss.** Do not repair this by committing the
foreign work into the publish. Preserve it under its own authorship first — it is
someone's reasoning, and folding it into a ceremony commit erases who did it and
why. Committing it separately also *fixes the reproducibility*, since the number
then genuinely follows from the tree. That is the move: commit, attribute, then
publish.

**The tree is one input the commit does not name; MACHINE LOAD is another.**
2026-08-02, the same failure through a different door. A full board published
`210_034_parser_wrapper` as a regression. The test completes cold in ~9s and had
been green in the twelve preceding snapshots; it blew the harness's 300s budget
because the machine was at load average 51–78 and the run starved it. Nothing
was wrong with the tree, the commit, or the compiler.

That budget is WALL CLOCK inside a parallel run, so a timeout is the one verdict
the harness can reach without learning anything about the code — and it was
recorded identically to a real failure. Downstream, the snapshot-to-snapshot diff
turned it into an `activity: regression` entry and the Discord post announced
"❌ 1 regressed" against the compiler. **That is the wrong-cause failure this
concept already calls the worse one, arrived at with a perfectly clean tree.**

So the claim generalises: *a published board is only checkable if every input
that can move it is named by the commit.* The tree is one such input. Machine
load is another, and there will be more. The fix that landed is narrow and it is
the right shape — never believe a first timeout; retry once and record the
failure only when the second attempt agrees, because a genuine hang reproduces
deterministically and a starved test does not.

**And do not repair the record by editing the measurement.** The honest
correction is forward: the next board shows it green, and the trail reads flake
then green. Rewriting a committed snapshot so an old post looks right is editing
a measurement to match a conclusion — see
[[frag-a-cost-the-optimizer-deletes-was-never-there]], which was retracted the
same day for that exact class of error.

**Third input, and the easiest one to walk into: the tree moving AFTER the
measurement.** 2026-08-02, same day, third time. The board was measured at
`94ae27eb` and correctly caught two tests going red. They were fixed in the
next commit, and the ceremony published from there — so the site read live
markers and said 1296 while the snapshot's own commit measured 1294, and the
activity stream announced two regressions that no longer existed.

Nothing here was wrong, exactly: the board was accurate about `94ae27eb`, the
page was accurate about now, and the fix was real. But the published number no
longer follows from the commit the snapshot names, which is the whole property
this concept exists to protect — and it happened without a dirty tree, without
a foreign session, and without machine load. Simply landing a commit between
measuring and publishing is enough.

So the rule the ceremony was missing is procedural and narrow: **between the
board and the publish, the tree does not move.** Fix something in that window
and you owe either a re-measure or an explicit note that the number and the
snapshot's commit have parted company. The three inputs found in one day —
someone else's uncommitted work, machine load, and your own next commit — are
different doors into the same room, and the general form is the one to hold:
*a published board is checkable only if every input that can move it is named
by the commit it cites.*

**Open:** the harness could refuse, or annotate. A snapshot could carry a
`dirty: [paths]` field and the site could show a board measured on an unclean
tree differently from one that is reproducible. Today the only thing standing
between a working-tree number and the front page is whether someone thought to
run `git status`. See also
[[frag-a-rename-can-improve-the-board-without-improving-the-compiler]] — the
other way a board number moves for reasons that are not the reason it appears to
have moved.

**Fourth door, and the one that stalls the site: the CONSUMER side reads the
live tree, not the snapshot.** The site's data generator (`generate-status.js`)
walks koru's on-disk markers (SUCCESS/FAILURE files) and pokes
`test-results/unit-tests.json` — it does NOT read the committed `latest.json`
or the git tree. So a ceremony that is procedurally perfect — snapshot measured
on a clean commit, commit landed, THEN site regen — still publishes whatever
the working tree looked like at regen time. Measured 2026-08-17: koru's main
carried abandoned mid-refactor WIP (interpreter discharge rewrite, library
build wiring), the working-tree markers reflected a partial cached run, and a
00:20 regen produced a nonsensical 601/1704 against a committed 1505/1691 —
a collapse of the headline board that no single commit explains. The inset
that saved the site was not machinery but a session refusing to commit garbage;
the site silently froze on its last good data instead.

Consequence for the ceremony: the site regen must run against a tree whose
marker state matches the snapshot's commit, which means the WIP must be
stashed BEFORE the site regen (not just before the koru run), or the regen
must read the snapshot instead of the tree. The general form holds — a
published board is checkable only if every input that can move it is named by
the commit it cites — and the site generator is another input the commit does
not name.
