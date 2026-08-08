---
type: belief
id: frag-a-worktree-isolates-the-tree-not-what-resolves-absolutely
provenance: 2026-08-08 — checked what was running before proposing a mergeback and found a full --no-cache board live in .claude/worktrees/store-clear, resolving its compiler modules through /usr/local/lib/koru/src, which is a symlink to the main checkout's src/
ts: 2026-08-08
---

# A worktree isolates the working tree, and not the thing a compiler run most needs isolated

The repo's answer to two sessions wanting the same checkout is *"that is what
`git worktree add` is for — ten seconds"* (`~/src/CLAUDE.md`), stated flatly
enough to close the question. It is good advice for editing and it is unsafe as
written for building, because the isolation it offers stops at paths that resolve
*relatively*.

A worktree's backend builds reach their compiler modules through
`/usr/local/lib/koru/src`, an absolute path, and that path is a symlink to the
main checkout. So the one resource a compiler run most needs isolated — the
compiler's own sources — is the one thing every worktree shares. An edit on main
lands inside a board running two directories away, and the reds it produces name
a file that session never touched.

The mechanics and the guard are in `koru/CLAUDE.md` where they can be acted on.
What this file holds is the part that generalises and the part that was believed.

## What was believed

That a worktree is an isolation boundary. Not stated anywhere in those words —
which is exactly the problem, because it is *assumed* by the advice to reach for
one whenever two sessions collide. The advice is about concurrency, and the
reader takes concurrency-safety with it. Nothing in the repo said otherwise, and
the existing warning about worktree boards
([[frag-a-spent-worktree-holds-the-only-copy-of-its-measurements]], plus the
under-reporting note in `koru/CLAUDE.md`) concerns what a worktree board *fails
to see*. Both are about the boundary leaking outward. This is the boundary
leaking inward, and nobody had looked in that direction.

## The general shape, kept narrow on purpose

An isolation mechanism isolates what its own naming scheme covers. `git
worktree` copies a tree, so it isolates tree-relative references and nothing
else. Every absolute path, every symlink, every installed artifact, every shared
cache is outside the boundary and stays shared — silently, because the mechanism
never claimed them and the user never enumerated them.

The narrow, correctable version of that: **for this repo today, a worktree does
not isolate a build.** If the resolution is changed so a worktree's builds reach
its own `src/`, this belief is wrong and should be corrected rather than kept as
a caveat. That fix is available and unclaimed; the symlink dates from 2025-12-18
and predates worktrees being used this way at all.

## The tell, and why the guard is a habit rather than a check

"While a suite is live" is unanswerable from inside your own checkout. `git
status` is clean, the branch is yours, nothing looks contended — and another
session's eleven-minute board is running against your sources. There is no signal
in the place a person looks. That is why the residue in `koru/CLAUDE.md` is a
command to run *before the first build* rather than a condition to evaluate: the
information is only available by asking the process table, and nobody asks
without a habit.

Related: [[frag-a-spent-worktree-holds-the-only-copy-of-its-measurements]] (the
same boundary, leaking the other way), [[frag-a-board-measured-on-a-dirty-tree-is-not-reproducible]]
(a board's trustworthiness as a property of the tree it ran against).
