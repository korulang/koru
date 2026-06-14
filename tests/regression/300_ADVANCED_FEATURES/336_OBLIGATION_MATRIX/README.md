# 336 · The Obligation Matrix

The permutation matrix of Koru's phantom-obligation discharge system — the
honest, complete spec of *what the compiler does with a live obligation*, as
one navigable grid.

Every cell is **one canonical test** that self-declares its coordinates in a
`CELL` marker file:

```
RESOURCE: String
STATE:    instance!
SCENARIO: drop-discard-branch
DESIGNED: auto-discharge
NOTE:     <one line: the behavior the ratified model designs for this cell>
```

`scripts/generate-obligation-matrix.js` walks this cluster, reads every `CELL`,
looks up each test's live status in the snapshot, and renders
`obligation-matrix.md`. The grid is a pure projection of the tests + the
snapshot, so **it cannot drift**: green = the compiler matches the cell's
designed behavior; red = it doesn't yet (the to-do list).

## Axes

**Rows** — `(resource × obligation state)`:
`String<view!>`, `String<instance!>`, `Connection<connected!>`,
`Connection<active!>`, `Transaction<started!>`, `Transaction<active!>`.

**Columns** — discharge `SCENARIO` (resolution × structure):

| scenario | designed behavior |
|---|---|
| `drop-single` | dropped at end of a single path → auto-discharge (void terminal) |
| `drop-multibranch` | live across multiple real-body branches → auto-discharge on each |
| `drop-discard-branch` | live on an all-discard `\| err _ \|> _` branch → auto-discharge there too |
| `escape-declared` | declared in the flow's output branch ctor → silent (caller owns) |
| `leak-boundary` | created in a subflow, neither discharged nor declared → KORU030 |
| `ambiguous-void` | two void disposers, none `[!]` → KORU030 "multiple discharge options" |
| `nonvoid-only` | only non-void disposers (a choice, e.g. commit/rollback) → KORU030 "call one of" |
| `transition-chain` | discharge needs a multi-step walk → currently KORU030 (chaining is an aspiration) |

## The model these cells encode

Auto-dischargeable(O) = a cycle-free walk from O to a fully-discharged state,
each step an event that (a) takes no params but the resource and (b) is void or
single-branch. Tie-breakers: prefer void/terminal; `[!]` only to break ties
between equal-level options. Today the walk is depth-1 (void terminals only);
`transition-chain` cells are red-by-design until chaining lands (see
`330_071_aspire_chain_autodischarge`). Escape is orthogonal — a contract check
("is it in my output?") run before the discharge walk.

Canonical fixtures only: `std/string` for String, and this cluster's own
`db.kz` for Connection/Transaction — so cells are directly comparable (no
per-test fixture drift).
