# Morning Koru feedback triage (autonomous run)

You are running headless on a cron, with no human watching. Your job: pull open
user feedback from korulang.org, **auto-fix the safe items and commit them on a
dated branch**, convert risky items into durable triage notes, then post one
digest to Discord. Work calmly and conservatively — when in doubt, triage, never
guess-fix.

Repos:
- Feedback CLI + Discord webhook: `~/src/korulang_org`
- Koru compiler / tests / docs (where fixes land): `~/src/koru`

Read `~/src/koru/CLAUDE.md` before changing anything in that repo — greenfield
rules apply, and regression runs use `--cache --parallel 8`.

## Step 1 — Pull open feedback

```bash
cd ~/src/korulang_org
node scripts/pull-feedback.js --json
```

Each item has: `_id` (full Convex id — its first 8 chars are the CLI id),
`category`, `content`, `pageUrl`, `priority`, `status`.

If there are **zero** open items: post **nothing** to Discord and stop. An empty
digest is an empty signal — worse than silence. Only post when there is actual
feedback to report.

## Step 2 — Understand each item

For every open item, view its test context:

```bash
node scripts/pull-feedback.js --context <id8>
```

(`<id8>` = first 8 chars of `_id`.) This shows the test code + expected output
and the page it's anchored to.

## Step 3 — Classify SAFE vs RISKY

**SAFE** (auto-fixable) — ALL of these must hold:
- The change is documentation/prose wording, a comment, a typo, a clarification,
  or rewriting a test's `.kz`/`.k` to a cleaner idiomatic form **where the
  expected output is unchanged**.
- It does **not** touch `src/*.zig` or `koru_std/**` (compiler + stdlib are
  always risky).
- It does **not** change language semantics, add a feature, or alter what any
  test asserts about behavior.

**RISKY** (triage only) — anything touching the compiler/stdlib, changing
behavior, adding features, ambiguous intent, or anything you are less than
confident about. **When in doubt, RISKY.**

## Step 4 — Act

**SAFE items:**
1. Make the edit in `~/src/koru`.
2. Find the affected regression test dir and run it:
   `cd ~/src/koru && ./run_regression.sh <test-id> --cache`
3. If it passes, keep the change. If it fails or breaks anything, **revert that
   item's edit** and downgrade the item to RISKY.
4. After all safe edits are in and green, commit them together on a dated branch
   created from `main` — **never commit to `main`, never push**:
   ```bash
   cd ~/src/koru
   git switch -c feedback-auto/$(date +%Y-%m-%d) 2>/dev/null || git switch feedback-auto/$(date +%Y-%m-%d)
   git add -A
   git commit -m "fix(feedback): auto-triage <date> — <item ids>" \
     -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```
5. Mark each committed item resolved so it doesn't reappear tomorrow:
   `cd ~/src/korulang_org && node scripts/pull-feedback.js --done <id8>`
   (This is reversible with `--reopen <id8>` — the digest tells Lars exactly
   what was closed.)

**RISKY items:** create a durable PRIORITY note in the test dir (this also
closes the feedback so it stops nagging), then it's waiting for Lars to review:
```bash
cd ~/src/korulang_org && node scripts/pull-feedback.js --priority <id8>
```
If the URL can't be mapped to a test dir, leave the item open and just describe
it in the digest.

## Step 5 — Post the digest to Discord

Build a concise digest and post it to the webhook in
`~/src/korulang_org/.env.local` (`DISCORD_STATUS_WEBHOOK`). Keep it under ~1800
chars (Discord caps at 2000); if long, trim per-item lines but never drop the
summary counts.

```bash
WEBHOOK=$(grep -E '^DISCORD_STATUS_WEBHOOK=' ~/src/korulang_org/.env.local | cut -d= -f2- | tr -d '"')
curl -sS -H "Content-Type: application/json" -d "$JSON" "$WEBHOOK"
```

The digest must contain:
- Date + total open count pulled.
- ✅ **Auto-fixed & committed**: branch name, commit sha, and one line per item.
  State plainly: "committed on a branch, NOT merged — review & merge, or
  `--reopen <id>` to send it back."
- 📋 **Triaged to PRIORITY** (for Lars to do): one line per item.
- ❓ **Couldn't map / left open**: one line per item, if any.

## Hard rules
- Never push. Never commit to `main`. All auto-fixes live on the dated branch.
- Never edit `src/*.zig` or `koru_std/**` autonomously — those are always RISKY.
- Prefer triage over fixing whenever you're not confident.
- Represent state exactly: report what actually happened (tests run, what passed,
  what you committed) — never inflate.
