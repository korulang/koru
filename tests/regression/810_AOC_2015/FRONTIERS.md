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

**CORPUS COMPLETE 2026-10-19.** Board: **49 AoC tests, 49 green, 0 red** —
the full Advent of Code 2015 corpus (day 25 is single-part, so 49 is the
whole event, not a truncated board). Every part is pure `.k` through the
real harness with leak checking on. This session closed the last five:
`810_072` (day 7 p2, circuit re-eval with wire-b override on the real
339-instruction input), `810_102` (day 10 p2, statement-scale look-and-say),
`810_112` (day 11 p2, second-next password), `810_222` (day 22 p2, Dijkstra
over packed combat states on the new `std/heap`), `810_232` (day 23 p2, the
real 47-instruction Turing-lock program at a=1). Earlier this campaign:
`810_191`/`810_192` (day 19, recursive IDDFS once the KORU030 borrow wall
came down — it was an unbound-argument misdiagnosis, not a checker defect),
`810_071` (day 7 p1), `810_221` (day 22 p1).

---

## 1. Day 19 — CLOSED 2026-10-19 (both parts green)

The arm-ownership suspicion this entry ended on was real but not where it
pointed: the KORU030 "no tracked phantom state" refusals were an
UNBOUND-ARGUMENT misdiagnosis — the checker cannot distinguish "name not
in scope" from "missing phantom state". Once arguments named real bindings,
list/set/map borrows crossed user-tor params cleanly (pins `660_038`,
`320_183`'s capture-cell hoist fix `5367dd6dc`), and the pre-written
recursive IDDFS for part 2 compiled almost verbatim. `810_191` (base-3
string codes + in-flow dedup) and `810_192` (IDDFS over rule strings) are
both green, leak-checked.

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

## Not gaps — all former reds closed

The five reds this section tracked (`810_071`, `810_221`, `810_101`,
`810_191`, `810_192`) are all green as of 2026-10-19 — the corpus has no
red left. `810_101` kept its statement-scale honesty boundary (the real
50-round look-and-say is a different surface); `810_102` pins the same
boundary for part 2.

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
