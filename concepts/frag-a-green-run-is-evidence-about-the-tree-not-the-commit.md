---
type: belief
id: frag-a-green-run-is-evidence-about-the-tree-not-the-commit
provenance: the .kz→.k migration, 2026-08-09. `git mv` staged twenty renames, `sed -i` then stripped the tildes in the working tree, and `git commit` wrote the index — so twenty files landed on main named `.k` with `~import` still in them, after two test runs had reported 21/21 and 11/11 green
ts: 2026-08-09
---

# The suite reads files; the push ships the index — and nothing compares them

A regression run opens files on disk. A commit publishes whatever is staged.
Those are two different pictures of the repository, and every workflow that edits
a file *after* staging it — `git mv` then an in-place rewrite, a formatter run
after `git add`, a fixup applied while the suite is running — makes them differ
without saying so. The run then reports green, truthfully, about a state nobody
else will ever receive.

**The green is not wrong. It is answering a different question than the one being
asked of it.** "Did this change work?" is heard as "is this change landed and
correct", and the run can only speak to the first half. The gap is invisible from
inside the loop: the tests pass, the commit succeeds, the push succeeds, and the
first contradicting signal arrives from a clean checkout, or from a CI machine,
or from another session — all of which are hours away and none of which will
name the cause.

Here the signal that surfaced it was incidental: running the doc generators and
noticing that twenty test inputs appeared as *modified* in `git status`, when no
generator writes into the test tree at all. Without that accident the twenty
would have sat on main until someone ran the suite from a fresh clone, and the
failure would have read as a compiler regression rather than a staging mistake.

**The general rule this belongs to:** a verification step and a publication step
must read the same bytes, or one of them is decoration. Any workflow that renames
and rewrites in two moves should stage after the rewrite, and any claim of the
form "tests pass, pushed" is two claims about two artifacts.

**What would correct this:** a harness that runs from a clean export of the
staged tree rather than from the working directory. Then the run really would be
evidence about the commit, and this fragment describes a hazard the machine no
longer allows. Until then the hazard is structural, not a lapse of care —
[[frag-a-board-measured-on-a-dirty-tree-is-not-reproducible]] is the same seam
seen from the other side, where the tree carries MORE than the commit rather
than less.
