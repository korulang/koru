# The Frontier Map — gaps the climb has named

**Contract (REWRITTEN 2026-06-12 by ruling — the old "all days stay green,
facets shrink" covenant is DEAD):** this is an INDEX, not a backlog. Every
entry points at executable truth: a RED test whose pure-`.k` form needs the
gap. A day that Koru cannot yet express sits RED on its gap — host facets
that did the day's work were LYING TESTS and are deleted, not shrunk. Green
is only ever earned by Koru doing the work. When a gap closes, the SAME
commit rewrites the red days that wanted it and greens them honestly;
delete the entry when its last red greens.

A gap-closing session starts here: pick an entry, read its pointers, close,
rewrite the ledgers, delete the entry.

**Swept 2026-08-26.** Two entries died this sweep, and one of them died
BACKWARDS: the phantom-unification "gap" was already closed by a ruled
spelling that its own pointers predated — they just sat unrespelled on
dead syntax while the ledger called the wall up. An index entry can be
stale in BOTH directions; check the join, not the prose.

Board after this session's closes: **44 AoC tests, 40 green, 4 red** (day 5 part 2 and day 10 part 1 went green 2026-08-26; see Closed).

---

## 1. Day 19 — a growing set of distinct strings plus a rule table

**The gap, now precisely characterized (attempted 2026-08-26).** The full
spelling exists (outer pass finds the molecule; inner read-lines replays
rules; index-of walks occurrences; results dedup into a string-map via
qualified-borrow threading) and every branch is armed — but the backend
refuses the deepest tor (`emit-at`, four levels of event-arming under
piped binds) with phantom KORU022 ok/err pairs. Bisected: gutting ONLY
`emit-at` clears all six diagnostics; the same topology two levels
shallower is green (day 5 part 2's walk, day 10's say-round). Related
measured friction, same session: a linear `|>` run whose void stages sit
before a branchy stage trips KORU031 choke-replication (void stages carry
empty payloads that clash with the branchy stage's), forcing an
always-true `if` template to break the chain; and void→bare-bind tails
demand branches in some contexts while identical shapes pass at top
level. The unifying suspicion: the point-free desugarer's stage/choke
model (ast_transform.zig ~960-1030) misjudges which stage owns arms once
binds and voids interleave past the first level.

**Pointers:** `810_191_day19_part1`, `810_192_day19_part2` (still red on
PARSE003 rot; the construction above is written and waiting in git his
tory of this session for the checker fix).

**This is the best-characterized frontier on the board** — the spelling
is done; only the checker's arm-ownership question blocks it.

## 2. Borrow surface for string views

**The gap.** `std/string:read` cannot say "this value lives as long as `s`."
Split landed stream-shaped and the safe subset is green; views-as-borrow
still has no spelling.

**Pointer:** `610_007_reject_dangling_slice` (must-error-passed). This is a
spelling question and it is Lars's — it also covers kopium hole 3 and the
borrow-only-drop gap, so one answer settles three.

## 3. Target-neutral expressions (doctrine, not blocking)

Green days still lean on Zig-flavoured leaves — `810_181/input.k:17` has
`@as(i64, @intFromBool(...))`, `810_031/input.k` compares `c == '>'`. Named
here so it is not rediscovered; nothing is red on it.

---

## Not gaps — reds that need work, not a decision

All five current reds fail at `PARSE003` or on their own stub bodies —
every one predates the bare-return migration and none has been respelled
onto the qualified-phantom spelling that 660_027 proved end-to-end
(see Closed). Respelling them is CONSTRUCTION against a live surface:

- **`810_071_day07_part1` / `810_221_day22_part1`** — declare the wire
  table and spell-script threading against `*List_i64<std/list:list>`
  params; the passthrough contract is green (`660_027`). Day 22's ledger
  math is fully worked out and python-oracled.
- **`810_101_day10_part1`** — body is a stub that reads lines and prints
  nothing; expected wants `312211\n6`. Either thread the growing sequence
  through user tors (now expressible) or carry it as a scalar/decimal
  encoding at statement scale.
- **`810_191` / `810_192`** — see entry 1 above.

## Closed since the last sweep — do not re-open

Regex group captures · the collection surface (`std/set`, `std/list`,
`std/string-map`, `std/grid`, `std/store`) · char/value dispatch
(`std/switch:char`, whose acceptance test `645_004_day08_switch` is named
for the very day the old entry called blocked) · mock × effect branches ·
effect lowering cut 1 · the toolchain pin batch · value recursion of tors
(`320_095`) · MD5 (`koru_std/crypto.kz`).

**Phantom-state unification for owned collection handles (old entry 1) —
CLOSED 2026-08-26, and it had been closable for weeks.** The ruled
qualified spelling (`<std/list:!list>` consumes, `<std/list:list!>`
issues, 2112/660_027) works end-to-end: `660_027` respelled past PARSE003
is GREEN, including linear transfer through a pure impl. The KORU030
`input:` vs `std.list:` mismatch the old entry described applies to the
BARE spelling, which the ruling had already superseded. One real defect
died making it honest: the emitter dropped the parser-lifted
`return_phantom`, emitting bare-return Outputs unqualified
(`pub const Output = *List_i64;`); it now resolves the base type's home
module from that phantom, matching what payload fields always did.

**Huge-alternation regex strategy (old entry 2) — DELETED 2026-08-26:**
its only pointer, day 5 part 2, went green WITHOUT any engine work (the
pristine spelling never needed the 676-alternation encoding — see that
day's ledger). The DfaTooLarge ceiling itself remains loud and named
(`640_004`); if a future day truly needs huge alternations, the entry can
be re-written then, with a pointer that actually points.

**Day 10 part 1 — CLOSED 2026-08-26.** The old ledger blamed ownership
transfer across fold iterations; the pristine spelling never crossed
anything owned. The sequence IS a number (day 11's ratified base-N
encoding, base 10): a round is a pure scalar transform, five rounds are
five chained binds, runs pack two decimal positions each, and the whole
walk is div/mod recursion with every return site a bind-a-call.

Day 6 — the 1000×1000 light grid the old index held up as the flagship case
for a collection surface — has been green **on `std/grid`** since
`54e32567`/`66464e48`.
