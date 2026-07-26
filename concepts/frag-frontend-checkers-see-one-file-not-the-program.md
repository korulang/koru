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

## Open, and it is the uncomfortable one

If a callee's declaration is invisible, a check that silently returns on a
missed lookup is not checking anything for cross-module calls. Branch coverage
is the case to measure first: `510_109` proved KORU022 reaches mid-chain, but
its fixture declares the callee in the same file. Whether a branching tor
imported from another module has its coverage enforced at all is **unmeasured**,
and the shape of this belief says the honest prior is that it does not.

That would make the reach work of 2026-07-26 correct and incomplete in the same
way twice over: reach along a chain, fixed; reach across a file boundary, never
examined. One probe settles it and it has not been run.
