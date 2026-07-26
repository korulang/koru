---
type: belief
id: frag-frontend-checkers-see-one-file-not-the-program
provenance: attempting to place KORU112; the checker was handed the entry file's items only, for a test fixture and a real package import alike
ts: 2026-07-27
---

# The frontend checkers are handed one file, not the program (belief)

`flow_checker.checkSourceFile` receives the **entry file's** items. Not the
program, not the import closure — one file, in both `frontend` and `all` modes,
for a local fixture and a packaged dependency alike. An imported module's
`proc_decl`s, `event_decl`s and host lines are simply absent from the slice the
checker walks.

This reads as wrong on first contact, because the checkers are where KORU022 and
KORU100 live and those diagnostics talk about callees. The resolution is that
those checks reason about invocations *written in the file being checked*; the
callee's declaration is looked up through `ast_items`, and when the callee lives
elsewhere the lookup finds nothing and the check returns quietly.

The merged program first exists at emission, where `ctx.ast_items` carries
everything — and where there is no reporter.

## What follows

- **A check needing an imported module's declarations has nowhere to stand.**
  Not "needs a condition added" — there is no pass with both the merged program
  and a way to report. KORU112 is reserved against that pass being built
  (`400_157`).
- **Read "the checker validates X" as "the checker validates X in the file it
  was given."** The distinction is invisible in any single-file test, which is
  what almost every fixture is.
- `shape_checker.checkSourceFile` has no production caller. It is reachable only
  from unit tests, so anything added there is dead on arrival — a trap for
  exactly the kind of decl-level check that looks like it belongs in a *shape*
  checker.

## The duplicate is what covers the gap

The obvious worry — that a check returning quietly on a missed lookup enforces
nothing across modules — was measured and is **false for branch coverage**. A
branching tor imported from another module, with an arm unhandled, is refused.

But not by the checker. The wording gives it away: what fires is the
auto-discharge inserter's KORU022, the *second* implementation of that rule,
which runs after the import fold and sees the merged program. The flow checker's
copy structurally cannot reach that program, and does not.

So the duplicate implementation that hid a reach gap
([[frag-the-minimal-test-of-a-wall-cannot-test-its-reach]]) is also the only
thing enforcing that rule across module boundaries. Collapsing the two into the
checker would silently delete cross-module coverage; collapsing them into the
inserter is the direction that keeps it. That is worth knowing before anyone
tidies them together on the grounds that one error code should have one voice.

It also answers where a whole-program check can stand: **the inserter runs
post-merge and has a reporter.** KORU112 has a home; it was never that no pass
existed, only that neither pass named "checker" was it.
