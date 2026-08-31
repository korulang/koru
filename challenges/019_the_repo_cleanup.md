---
challenge: repo-cleanup
kind: frame
status: standing
yields: one repo-hygiene pass, done to the checklist — committed junk purged, gitignore holes closed, the working tree verified, the preserves named
family: toolchain
---

*Walker context — the recurrence that earned this frame. Junk keeps arriving
because the root `.gitignore` is a whitelist that admits it by default:
`/*` does not ignore directories (`!*/` re-includes every one) or dotfiles
(`!.*` re-includes every one), so a scratch directory dropped at the repo
root is tracked until someone names it. The near-miss was a 2.8 MB
`.shell-probe/` that a ceremony's `git add -A` almost swept into a commit
(2026-08-07, documented in the `.gitignore` header). The first real
occurrence fired: `.orphan-staging/`'s build artifacts — `backend.zig`,
`*.err`, `FAILURE`, `program.ast.json` — rode a `git add -A` into the
publish commit `74c9fd1d`. The first full pass was `becc6a7f` (2026-08-31):
purged committed backups and dead spikes, closed the holes (`*.bak`,
`*.bak2`, `*.backup`, `.orphan-staging/`), moved stale docs, purged ~21k
ignored artifacts in the working tree. Within a day, 240 `zig-out-run-*`
directories regenerated. A cleanup is never a one-shot — that is exactly why
this is a replayable frame, not a chore you cross off.*

*The second pass (same day) added the discipline the first pass's author
already knew: verify before you delete, against the current tree, on both
clocks. The 2026-08-30 architecture review listed `.bak` files the purge had
deleted hours earlier and named six "dead" modules live on the backend
graph — its file list was true at write time and false within 24 hours
(`frag-zig-build-does-not-compile-all-of-src`,
`frag-a-header-citing-a-pin-is-a-measurement-at-write-time`). This frame
bakes that discipline in as a step, not a footnote.*

*The first replay under that discipline (2026-08-31) purged 5,511 committed
files — a cargo `target/` tree, a unikraft build tree, 1,041 board
snapshots, benchmark binaries, generated AST dumps — and left the deny-list
walls that keep them out. The committed tree is the other half of this
frame's subject.*

*The git wall (2026-09-01, `57ca6bc5`) compiles those deny-lines into the
commit boundary: `scripts/git_wall.sh` uses `git check-ignore --no-index` as
the oracle, pre-commit runs `--staged`, the suite runs `--committed`.
Grandfather rows live in `scripts/git_wall_allowlist.txt` and **shrink** as
this frame's replays purge them — the wall never widens. This frame still
replays for committed rot and allowlist shrink; the wall holds the line
against fresh junk.*

---

## The brief (sealed — you are the contestant)

Run one full repo-cleanup pass, to the checklist. The worked example is
`becc6a7f` — `git show becc6a7f` before you start; it is the shape this
frame replays. Your pass will differ: junk accumulates differently each
time, and the variance this frame is for is *which* junk, *which* holes, and
*which* preserves the current tree holds.

## The committed tree — the repo as a clone sees it

The working tree is not the repo. A cleanup that stops at untracked junk has
missed what the ceremonies shipped: build artifacts, binaries, tarballs, and
generated dumps — tracked, committed, and read by nobody. Measured
2026-08-31: 12,716 tracked files, of which the compiler was 102 — the rest
was a bevy `target/` (1,190), a unikraft build tree (3,248), 1,041 board
snapshots, benchmark binaries, and 14 AST dumps, all purged in one session.

- **Inventory with git's predicate, and read the sizes.** `git ls-files` +
  `git ls-tree -r -l HEAD`. The biggest blobs are the story: cargo `target/`,
  compiled binaries, tarballs. A tracked file is not deliberate; it is
  committed.
- **Reader-verification before any deletion.** `git grep` each class across
  the tracked tree. Nothing reads it and nothing builds it → purgable. The
  build consumes it → bootstrap, stays (`koru_std/compiler.zig` is generated
  but wired into `build.zig`). **Resolve symlinks before removing their
  targets**: `test-results/latest.json` was a symlink to a dated board, and a
  purge that deleted the board broke the snapshot the website reads — the
  tooling's "no snapshot" was the tell.
- **One class per commit, deny-list in the same commit.** Delete the class,
  add the ignore rule (`target/`, `*.rlib`, `.unikraft/`, `**/program.ast.json`,
  `test-results/2*.json`), and the commit is both the purge and the wall.
- **Verify after.** `zig build`, a filtered regression run, and the status
  tooling (`generate-status.js`, `--status`) — a purge that breaks the
  snapshot read is a purge that broke the repo.

## Pre-flight

- **No suite may be live.** `pgrep -fl "run_regression|zig build"` — a purge
  that touches `src/` or `koru_std/` while a board is running turns reds
  that name your own edit. This includes boards in other worktrees.
- **Read the ground before you move it.** `git status`, `git log` since the
  last cleanup commit, `git worktree list` — junk may live in a worktree
  while main is clean.
- **Pin your tree.** `git rev-parse HEAD` + branch. Your pass names the tree
  it measured.

## Step 1 — Inventory with the enforcer's predicate

`git ls-files` is the predicate: tracked = live surface or deliberate;
untracked-and-unignored = future junk. Count with git's predicate, never
your reading of the tree. **Do not trust any prior scan's file list** — the
`.bak` list from 2026-08-30 was true at write time and gone within a day.
Re-derive every candidate this session.

## Step 2 — The whitelist hazard

Read the `.gitignore` header comment before touching anything. `/*` ignores
root files, but `!*/` and `!.*` hand directories and dotfiles back. For
every junk class you found, ask *what hole let it in?* — and close that
hole. A purge without a hole-closing is a rerun, not a cleanup.

## Step 3 — Verify before you delete

For every candidate, confirm it is junk **this session**, on both clocks:
`build.zig`'s `exe.root_module` AND the backend graph in
`koru_std/compiler.kz` / `koru_std/build.zig`. A file in either graph is
live, however "unused" it looks from the top-level build. Then rule it:

- **not a blocker** — verified junk (tracked backup, dead spike, generated
  artifact, scratch dir). → Delete.
- **blocker** — it is live, deliberate, or preserved. → Keep, and name why.
- **unmeasured** — you have not checked it this session. → Stop talking
  about it. Never delete on an old claim.

## Step 4 — The preserves

Name what must not be touched *before* you delete anything: `.env.local`,
`.vercel/`, `.claude/settings.local.json`, `.fallow/`, `.koru-studio/`,
`zig-out/`, and any worktree symlinks (`becc6a7f`'s list). Deliberate
structures are not junk: `concepts/`, `signals/`, `challenges/`, and
`test-results/` are the belief corpus and the ceremony snapshot, tracked by
design. The 2026-08-30 review's worst error was mislabeling these as
clutter — a cleanup that purges the corpus is the frame's one unforgivable
move.

## Step 5 — Working-tree hygiene

`git clean -fdX -n` must list only the preserves. Ignored regenerables
(`zig-out-run-*`, `.zig-cache`, per-test backend builds) can be purged for
disk — but say in your commit that they regenerate; the next pass will find
them again.

## Step 6 — Verify the result

- `git status` shows only this commit's changes.
- `git clean -fdX -n` lists only the preserves.
- A control that was green at HEAD is still green.

## What "done" looks like

- Each junk class: found, purged, and its hole closed — or refused with the
  reason, named out loud.
- The preserves list in the commit message or the pass notes.
- The measured tree pinned.
- The commit says what regenerates, so the next replay starts from honesty.

## Failure modes

- **Purging deliberate infrastructure** — `concepts/`, `test-results/`, the
  corpus. Unforgivable; the review did it in prose, do not do it in git.
- **Deleting on an old claim** — the `.bak` lesson. Re-check this session.
- **Deleting without naming the preserves.** The list comes first.
- **Running while a suite is live.** The reds will name your own edit.
- **`git add -A` sweeping junk into a ceremony commit** — the `74c9fd1d`
  sin. Stage deliberately.
- **A purge that leaves the hole open.** The gitignore line is the actual
  fix; the deletion is the symptom.
