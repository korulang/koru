---
type: belief
id: frag-effect-continuation-marker-kinds
provenance: introduced by the 400_171/172 pin — the !/| marker-kind mismatch is silently accepted, 2026-07-23
ts: 2026-07-23
---

# `!` and `|` are separate branch KINDS — the marker must match the call

Koru has two branch markers and they are **separate kinds, not interchangeable
syntax**:

- **`!` — effect arms.** Handle the effects/events an invocation *fires*: `query`
  and `watch` install standing rules, lifecycle interceptors (`! inserted` /
  `! removed`), streaming (`! line` / `! row`), capture (`! as`). The invocation
  is a producer; the `!` arms are its effect handlers.
- **`|` — continuation / outcome branches.** The outcome a call *returns* — you
  match which one it yielded: `insert … | row | full`, `from-page … | ok | err`,
  `take … | item`. A sum-type result.

**The rule (Lars, 2026-07-23): the marker at a call site MUST match the event's
declared branch-kind, and the mismatch is a hard FRONTEND reject.** `!` and `|`
are to be kept extremely well separated — an effect marker on an outcome-branch
call, or a continuation marker on an effect, is not a stylistic choice, it is a
kind error. (Open edge, leaning "no": whether one event may declare both a
`!name` and a `|name` sharing a name — probably disallowed.)

## Current state — the wall is NOT built (the defect this fragment pins)

koru does **not** enforce this today (found reviewing `koru-examples/todo/`):

- `! item` on `take`'s outcome branch `| item` **compiles with no diagnostic and
  MISCOMPILES** — the owned obligation (`free(s: taken.label)`) never discharges,
  so the program **leaks at runtime**. Worst class: a wrong program with no
  compile-time wall. Pinned `400_171` (MUST_FAIL, FRONTEND_COMPILE_ERROR).
- `| query` on the `query` effect is silently accepted and runs benignly. Pinned
  `400_172`.

The markers ARE semantically distinct *to the compiler* — the correct `| item`
form is leak-clean and only the marker changed to produce the leak — so this is a
**missing frontend wall**, not lenient-by-design grammar. The fix: a frontend
check matching the call-site marker to the invoked event's declared branch-kind,
rejecting the mismatch with a koru-level diagnostic (flip 400_171/172 to green
when it lands). Belongs to the "build the emission-seam walls" program — but this
one sits earlier, at the frontend, before any host code is emitted.
