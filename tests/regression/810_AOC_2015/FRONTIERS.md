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

**Swept 2026-08-07.** The index had run 8 weeks without its delete rule ever
firing, and seven of its nine entries described gaps that had closed —
including two whose closers landed within days of the entry being written.
An index nothing re-checks aims the next session at work already done, and
this one was doing exactly that on its first read. Entries below are what
survived a check against the board; the deleted ones are in git.

Board at the sweep: **43 AoC tests, 36 green, 7 red.**

---

## 1. Phantom-state unification for owned collection handles

**The gap.** A collection handle minted by the stdlib carries a phantom
state namespaced to the module that minted it. Pass it into a tor the
program declares itself, or thread it through a label-fold's continue
payload, and the state never unifies with the parameter's:

    error[KORU030]: expected 'input:list' but got 'std.list:list!'

So a program can own a collection and still not be able to hand it to its
own helper. Every AoC day that wants a working set threaded through a loop
dies here.

**Pointers:** `810_071_day07_part1` (frontend), `810_101_day10_part1`
(output — prints `312211`, misses the length), `810_221_day22_part1`
(frontend).

**Why it is not in the old index:** it was hidden behind entries 2 and 8,
which blamed "no collection surface" and "no recursion spelling." Both of
those closed; this stayed, and it is what those days were actually waiting
on. The adjacent bind-chain case was fixed and ruled 2026-07-12
(`concepts/frag-phantom-bind-chain-threading.md`), so the area is live —
this specific unification is the unproven one. No green test anywhere
passes an owned collection handle into a user-declared tor.

**Related, and probably the same decision:** `690_018_store_declared_key_addressing`
is TODO. String-keyed random access is what day 7's wire table wants.

## 2. Regex: huge-alternation engine strategy

**The gap.** The 676-alternation backreference encoding blows the DFA
(`DfaTooLarge`). The loud failure was the previous cut's contribution; the
strategy — lazy DFA, or NFA simulation above a size threshold — was never
chosen.

**Pointer:** `810_052_day05_part2` (backend-exec; currently `KORU047`,
`nice2` unimplemented, because the host leaves were deleted under the
pure-Koru invariant).

## 3. Borrow surface for string views

**The gap.** `std/string:read` cannot say "this value lives as long as `s`."
Split landed stream-shaped and the safe subset is green; views-as-borrow
still has no spelling.

**Pointer:** `610_007_reject_dangling_slice` (must-error-passed). This is a
spelling question and it is Lars's — it also covers kopium hole 3 and the
borrow-only-drop gap, so one answer settles three.

## 4. Day 19: a growing set of distinct strings plus a rule table

**The gap, honestly stated as uncertain.** Store now has owned-string
columns green (`690_053`, `690_060`–`690_065`, `690_238`) and
declared-capacity inserts (`690_011`), so this may already be portable. No
green test does string-dedup across rows, so it is unproven rather than
blocked.

**Pointers:** `810_191_day19_part1`, `810_192_day19_part2`.

**This is the best fresh attempt on the board** — the one place the store
work plausibly closes an AoC red that nobody has tried since it landed.

## 5. Target-neutral expressions (doctrine, not blocking)

Green days still lean on Zig-flavoured leaves — `810_181/input.k:17` has
`@as(i64, @intFromBool(...))`, `810_031/input.k` compares `c == '>'`. Named
here so it is not rediscovered; nothing is red on it.

---

## Not gaps — reds that need work, not a decision

- **`810_122_day12_part2` is an emitter bug with a golden answer waiting.**
  Pure `.k`, empty ledger, and the emitted Zig says
  `local constant 'result_c1_0' shadows local constant from outer scope`.
  Nothing about the language blocks this day; fix the emitter and it greens.
- **Four of the seven reds die before reaching their gap.** `810_071`,
  `810_191`, `810_192` and `810_221` all fail at `PARSE003` on the stale
  single-branch-payload declaration form — `-> T` became mandatory in the
  bare-return migration (`8b2603ca`, `f132fa25`). Respelling them is a
  prerequisite for even observing whether entry 1 still blocks them.

## Closed since the last sweep — do not re-open

Regex group captures · the collection surface (`std/set`, `std/list`,
`std/string-map`, `std/grid`, `std/store`) · char/value dispatch
(`std/switch:char`, whose acceptance test `645_004_day08_switch` is named
for the very day the old entry called blocked) · mock × effect branches ·
effect lowering cut 1 · the toolchain pin batch · value recursion of tors
(`320_095`) · MD5 (`koru_std/crypto.kz`).

Day 6 — the 1000×1000 light grid the old index held up as the flagship case
for a collection surface — has been green **on `std/grid`** since
`54e32567`/`66464e48`.
