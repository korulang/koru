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

**Open:** the harness could refuse, or annotate. A snapshot could carry a
`dirty: [paths]` field and the site could show a board measured on an unclean
tree differently from one that is reproducible. Today the only thing standing
between a working-tree number and the front page is whether someone thought to
run `git status`. See also
[[frag-a-rename-can-improve-the-board-without-improving-the-compiler]] — the
other way a board number moves for reasons that are not the reason it appears to
have moved.
