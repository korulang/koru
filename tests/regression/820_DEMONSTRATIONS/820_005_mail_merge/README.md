# mail_merge

**One-line pitch**: render one letter per row of a table, substituting `{{field}}` placeholders with that row's values.

**State**: pristine-green

## The task

Mail merge. A letter template containing `{{key}}` placeholders plus a
table of recipient records; emit one finished document per record with each
placeholder replaced by that record's value. A placeholder that names no
field is left standing verbatim, the way a real merge flags an unfilled
slot.

## How Koru does the work

- `recipients` is a `std/store` whose `name` column is owned
  `*String<instance!>` — custody moves in on `insert`, `! query` hands out a
  read-only borrow per row, and store teardown frees every live element.
- `merge` is a subflow that runs `std/string:split` on `"{{"`, then
  destructures each `key}}rest` piece with a `std/regex:match` named-group
  pattern — literal pieces can't match, so no piece counter is needed.
- `emit` is a subflow that maps key → field with a plain `if` chain and
  re-finds the current row inside its own `! query` by matching `[ordinal]`.
- The current row's ordinal and the output buffer cross the `! piece`
  boundary through module-scope stores (`curi` singleton, `docs` cell) —
  proc-effect arms lower to context-free fns, so stores are the ferry.
- Procs are leaves: `split`/`append`/`clear`/`from-page` are std calls and
  `fmt:ln` is the compile-time render that bridges a `*String` borrow into
  `append`'s slice parameter. No host-code accumulators.

## Gap filled

Against the standing catalog (dedup by description — hanoi, crc_manifest,
access_log were proven on a parallel branch this morning): hanoi is tree
recursion, crc_manifest is a checksum verifier (its owned-String custody is
a mechanism shared here, not the task), access_log is record parsing plus
group-by — all three CONSUME structured input; none GENERATES text from a
template. Outside 820: 690_190 is a store→text→store codec (serialize/
parse, not templating); the 810 AoC days parse text but never generate it
from a table; nothing in 800_CHALLENGES does placeholder substitution.

## Frontier

None — green. Two walls found en route and spelled around, worth noting for
the next contestant: a `! piece` arm sees module scope only (a subflow's own
params do not cross — raw Zig `'x' not accessible from inner function`, no
Koru diagnostic yet), and a `=>` branch resolution cannot fire inside a
`! query` arm (KORU102 — the arm grafts into a void synthesized unit).

## Output

Three merged letters, one per recipient; `{{mystery}}` survives unexpanded
on every line, which is what pins the unknown-key passthrough.
