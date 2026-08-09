---
type: belief
id: frag-the-head-label-sugar-stops-at-the-subflow-body
provenance: session 2026-08-09 (Lars + Claude) — "Let's get Rusty"; isolated out of the drag-race entry's breakage
ts: 2026-08-09
tags: [koru, emitter, bare-return, head-label, subflow, diagnostics]
---

A named label with a binding on a **bare-return** tor is binding sugar:
`seed() | at p |>` binds `p` to seed's `-> i64` result. It is a real feature,
pinned by `210_195`, `330_121` and `330_122`, and the label name is arbitrary by
design — it is a label, not a tag.

**The sugar is not uniform across positions.** It works nested in a chain (~60
sites) and it works at the flow head (taught there on 2026-07-31 by `4d30f252`,
which passed the callee path into `emitContinuationList` so `callee_bare_return`
could be computed). It does **not** work in a subflow BODY head —
`tick = std/time:now() | t n |> …` — because that position is emitted by a
different machine, the return-switch path
(`emitSubflowContinuationsWithDepth`), which has no equivalent of
`callee_bare_return` and emits a tag dispatch over the returned scalar:

    const result = koru_std.koru_time.now_event.handler(.{ });
    switch (result) { .t => |n| { … } }

`result` is an `i128`, so the author is handed
`expected type 'i128', found '@Type(.enum_literal)'` — raw Zig about a file they
never opened, which is the exact leak `210_195`'s own comment names as its
guarded seam. Pinned RED as `210_200`.

**Why this belief is worth holding rather than just fixing:** the 31 July commit
opens by naming the shape — *"three lowerings disagreed about a named label on a
`-> T` tor"* — and closed two of the three. The generalisation nobody wrote down
is that **the head-label sugar is implemented per position, so the correct
question after teaching one position is not "does it work now" but "how many
positions are there, and which ones did I teach"**. The subflow body is a fourth
lowering the commit did not enumerate. There may be more; a JS-target head, a
label-fold arm and a transform-grafted head are all unchecked.

Cost of the gap, measured: it sat unnoticed from at least 12 July to 9 August
inside `benchmarks/workloads/prime_sieve_drag_race`, the program behind our
published result against Rust, and its symptom is a host-language type error
rather than a Koru refusal — so it reads as "the benchmark is broken" rather
than "the compiler is missing a case."

**Standing debt, recorded so the shape does not outlive the memory:** the entry
currently spells that line `std/time:now(): n`, which is a REROUTE around this
defect and is marked as one in the file. It is not the shape the program wants.

Open questions:
- Whether `callee_bare_return` can be lifted out of `emitContinuationList` into
  something both paths consult, rather than taught a third time.
- Whether the return-switch fast path should simply BAIL for a bare-return
  callee the way it already bails for labels, taps and transformed subtrees —
  cheaper than teaching it, and its bail-out list is the established pattern.
