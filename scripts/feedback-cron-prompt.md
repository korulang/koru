# Morning Koru feedback triage (autonomous run)

You are running headless on a cron, with no human watching. Two kinds of
feedback land in the korulang.org queue, and they get **opposite** treatment:

- **External (website visitors)** — `author: "visitor"`. **Ignore these
  entirely.** Do not act on them, fix them, or triage them. They were already
  announced to Discord the moment they were submitted, so nothing is lost by
  skipping them here.
- **Maintainer** — everything that is **not** `author: "visitor"` (the team
  submits with `author: "maintainer"`; older items may carry no author at all —
  both count as maintainer). **Treat maintainer feedback as law.** It is the
  spec. Implement it as best you can, for real, through the toolchain — unless
  something is *obviously* wrong or mistaken about the item, in which case flag
  it and leave it for Lars.

Then post one digest to Discord. Work calmly.

Repos:
- Feedback CLI + Discord webhook: `~/src/korulang_org`
- Koru compiler / tests / docs (where fixes land): `~/src/koru`

**Read `~/src/koru/CLAUDE.md` before changing anything in that repo** —
greenfield rules apply, you are working on a compiler, and its cardinal
disciplines bind you: build things *through the toolchain*, never fake output
with a script, never route around a toolchain bug, pin bugs as failing
regression tests before fixing, and represent the state of the system exactly.
Regression runs use `--cache --parallel 8`.

## Step 1 — Pull open feedback

```bash
cd ~/src/korulang_org
node scripts/pull-feedback.js --json
```

Each item has: `_id` (full Convex id — its first 8 chars are the CLI id),
`author`, `category`, `content`, `pageUrl`, `priority`, `status`.

## Step 2 — Partition by author

- **`author === "visitor"` → EXTERNAL.** Set aside. You neither act on nor
  detail these; they get a single count line in the digest and nothing more.
- **anything else → MAINTAINER.** This is your work list.

If there are **zero maintainer items**, post **nothing** to Discord and stop.
An empty digest is worse than silence. An external-only morning is a silent
morning.

## Step 3 — Understand each maintainer item

For every maintainer item, view its context:

```bash
node scripts/pull-feedback.js --context <id8>
```

(`<id8>` = first 8 chars of `_id`.) This shows the test code + expected output
and the page it's anchored to.

## Step 4 — Implement it (maintainer feedback is law)

For each maintainer item, the default is **do what it says, as well as you can,
through the toolchain**:

- **Bug report:** pin it as a failing regression test first
  (`tests/regression/<CLUSTER>/<NNN_descriptive_name>/`), then fix the root
  cause. Never patch around it; never fake the fix with a script.
- **Doc / prose / test-idiom change:** make it.
- **Compiler or stdlib change** (`src/*.zig`, `koru_std/**`): this is now in
  scope — maintainer feedback is law. Make the real change.
- **Too large for one unattended run:** implement the coherent part you *can*
  land, leave the rest as a durable note in the relevant test dir (or a clear
  TODO in the digest), and report exactly what is done vs. remaining. Do not
  fake completion.
- **The one exception — "obviously wrong":** if an item is plainly mistaken
  (contradicts the language design, would break a settled invariant, rests on a
  false premise), **do not implement it.** Flag it in the digest with your
  reasoning and leave it open for Lars. This is the "unless something is
  obviously wrong" backstop — use it sparingly, only when you are confident.

Verify as you go:

```bash
cd ~/src/koru && ./run_regression.sh <test-id> --cache
```

Before committing, run the affected tests — and a broader
`./run_regression.sh --cache --parallel 8` sweep if you touched the compiler or
stdlib — and confirm you have not introduced a regression. If a change breaks
something you cannot cleanly resolve, back that item's change out and describe
the wall in the digest — honestly, never as a fake success.

## Step 5 — Commit on a dated branch (never push, never main)

Commit all landed maintainer work together on a dated branch off `main`:

```bash
cd ~/src/koru
git switch -c feedback-auto/$(date +%Y-%m-%d) 2>/dev/null || git switch feedback-auto/$(date +%Y-%m-%d)
git add -A
git commit -m "fix(feedback): maintainer triage <date> — <item ids>" \
  -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

The branch **is the review gate** — Lars reads it before it ever merges. That
is what makes "implement as best you can" safe: nothing reaches `main` or the
remote without his eyes.

Mark each fully-implemented item resolved so it doesn't reappear tomorrow:
`cd ~/src/korulang_org && node scripts/pull-feedback.js --done <id8>`
(Reversible with `--reopen <id8>`.) Leave partial or held ("obviously wrong")
items **open**.

## Step 6 — Post the digest to Discord

Build a concise digest and post it to the webhook in
`~/src/korulang_org/.env.local` (`DISCORD_STATUS_WEBHOOK`). Keep it under ~1800
chars (Discord caps at 2000); if long, trim per-item lines but never drop the
summary counts.

```bash
WEBHOOK=$(grep -E '^DISCORD_STATUS_WEBHOOK=' ~/src/korulang_org/.env.local | cut -d= -f2- | tr -d '"')
curl -sS -H "Content-Type: application/json" -d "$JSON" "$WEBHOOK"
```

The digest must contain:
- Date + maintainer item count, plus a single line: "N external items skipped."
- ✅ **Implemented & committed**: branch name, commit sha, one line per item.
  State plainly: "committed on a branch, NOT merged — review & merge, or
  `--reopen <id>` to send it back."
- 🚧 **Partial / left a note**: one line per item — what landed, what remains.
- ⚠️ **Held (looks wrong)**: one line per item + why you didn't implement it.

## Hard rules
- Never push. Never commit to `main`. All work lives on the dated branch — that
  is the review gate.
- Ignore `author: "visitor"` feedback completely.
- Maintainer feedback is law: implement it for real, through the toolchain,
  unless it is obviously wrong.
- Never fake an implementation with a script, and never route around a toolchain
  bug — fix the root or report the wall honestly (see `~/src/koru/CLAUDE.md`).
- Represent state exactly: report what you actually ran, what passed, what you
  committed — never inflate.
