---
type: belief
id: frag-a-bare-return-crosses-the-registry-as-a-value-not-an-obligation
provenance: 410_003/410_004 respelled to the modern `-> string<opened!>` spelling report 0 tracked handles and never fire auto-discharge; the same programs with the obligation on a branch payload (`| opened string<opened!>`) track 1 and discharge (410_003/004/005, 430_051 all green that way). Measured 2026-07-31 during the interpreter garden.
ts: 2026-07-31
---

# A bare return crosses the registry as a value, not an obligation (belief)

The runtime registry's obligation extraction reads obligations off an event's
*declared branches*. A bare-return tor (`-> T<state!>`) has no branches — its
value crosses the dispatch boundary on the `__type_ref` channel with the empty
branch name — and its phantom obligation is silently absent from the scope's
`creates_obligations` table. The interpreter then runs the program with a
handle pool that never hears about the resource: no tracking, no
auto-discharge, no exhaustion cleanup.

This matters more than a corner case because the bare return is the *ruled*
modern spelling for exactly the single-resource-producing events (open, create,
acquire) that obligations exist for — the compiled path enforces their
obligations, the interpreted path drops them. Until the seam is closed, the
interpreter's phantom story covers only branch-payload obligations, and any
capability-scoped host (playground, kopium) that registers a bare-return
producer gets a leak the compiled world would have refused.

The measured green mirror: obligations on branch payloads flow end to end —
tracked handles, auto-discharge on normal exit, auto-discharge on budget
exhaustion. The machinery is sound; the extraction just predates the
bare-return ruling.

Related: [[frag-a-red-tests-nothing-past-its-first-wall]] — found while
burning down that frag's migration debt in the 410/430 corpus.
