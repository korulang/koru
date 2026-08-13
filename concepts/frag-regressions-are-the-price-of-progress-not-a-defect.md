---
type: belief
id: frag-regressions-are-the-price-of-progress-not-a-defect
provenance: session 2026-08-13 (Lars ruling, during the Clean Code evaluation) — "taking a board from green to red is preferred across the board. We're not a real language, we're a human and an LLM monkeying around. Fearlessly failing forward. But let's worktree everything."
ts: 2026-08-13
---

# Regressions are the price of progress, not a defect — fail forward, worktree everything (regime)

Koru is a laboratory, not a product: no external clients, a human and an LLM
driving. The board's green is a **state**, never a **contract**. When a change
needs to regress tests to progress the compiler, the regression is payment, not
damage. Fear of red stalls forward motion, and stalling is the only failure that
is actually expensive. A red that is the honest price of a landed change is
welcome; it gets read, named, and either fixed forward or pinned with a note.

The board's honesty discipline is **not repealed** by this regime — it is what
makes red safe to accept. The corpus's existing walls stand: never fake a green
([[frag-a-misnamed-assertion-is-silently-no-assertion]]), never delete a failing
test to get a clean board ([[frag-a-pass-marker-is-not-a-product-marker]]),
never edit a measurement to match a conclusion
([[frag-a-board-measured-on-a-dirty-tree-is-not-reproducible]]), and never wave
off an *unexplained* flip — red that appears for no change is still a signal to
read ([[frag-a-test-can-be-load-bearing-by-accident]]). What the regime removes
is the *fear* of red, not the *reading* of red. A red that nobody reads is not
failing forward; it is drifting.

Worktrees are the enabling practice: all work happens in a worktree, main stays
clean and mergable, experiments are disposable, and a red board lives in the
worktree that caused it, never on the trunk. Measurements taken inside a
worktree are preserved like any other
([[frag-a-spent-worktree-holds-the-only-copy-of-its-measurements]]). Failing
forward cheaply requires that failure never touches main.

Wrong-ability: this belief dies if the board stops being read — reds
accumulating unexamined, or the "payment" frame becoming a licence to ignore
what a regression was protecting. The line is that regressions are acceptable
*because* they are read; the day red becomes invisible is the day this was wrong.
