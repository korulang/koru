---
name: pull-feedback
description: Pull and manage feedback from korulang.org. Use to see what users are reporting about tests/documentation, prioritize work, and mark items resolved.
---

# Feedback Tool

Pull user feedback from korulang.org (stored in Convex) and manage it.

## Commands

Run from the korulang_org directory:

```bash
cd ~/src/korulang_org

# List all open feedback (default)
node scripts/pull-feedback.js

# View a specific item (use 8-char ID prefix)
node scripts/pull-feedback.js abc12345

# View with full test context (code + expected output)
node scripts/pull-feedback.js --context abc12345

# Mark as resolved
node scripts/pull-feedback.js --done abc12345

# Mark as won't fix
node scripts/pull-feedback.js --wontfix abc12345

# Reopen a closed item
node scripts/pull-feedback.js --reopen abc12345

# Create PRIORITY file in the test directory from feedback
node scripts/pull-feedback.js --priority abc12345

# Filter by category
node scripts/pull-feedback.js --category 310-comptime

# Full JSON dump
node scripts/pull-feedback.js --json

# Tonight's work: 5 lowest-rated pages with feedback
node scripts/pull-feedback.js --lowest

# List all rated pages (high to low)
node scripts/pull-feedback.js --ratings

# List rated pages (low to high)  
node scripts/pull-feedback.js --ratings --low

# List pages with specific rating (1-5)
node scripts/pull-feedback.js --ratings 1
node scripts/pull-feedback.js --ratings 5
```

## Workflow

**Quick start for tonight's work:**
1. Run `--lowest` to see the 5 lowest-rated pages with feedback
2. Pick a page, fix the issues
3. Re-rate the page on korulang.org after improving it

**Finding best practices / gold standard examples:**
- Run `--ratings` to see all rated pages (highest first)
- Run `--ratings 5` to see only 5-star pages (curated examples)
- Use these as templates when creating new tests or documentation

**Full feedback workflow:**
1. Run `/pull-feedback` to see open items
2. Use `--context <id>` to see the full test code for an item
3. Either:
   - Fix the issue directly, then `--done <id>`
   - Use `--priority <id>` to create a PRIORITY file in the test dir (auto-closes feedback)
4. Delete PRIORITY file when the work is complete

## Notes

- IDs are 8-character prefixes of the full Convex ID
- Prioritized items (P1) appear first in the list
- Feedback is URL-anchored to specific pages on korulang.org
- The `--priority` command maps URLs back to test directories in this repo

## Requirements

- `~/src/korulang_org/.env.local` must contain:
  - `PUBLIC_CONVEX_URL` - Convex deployment URL
  - `ADMIN_SECRET` - Required for mutations (done/wontfix/reopen)
