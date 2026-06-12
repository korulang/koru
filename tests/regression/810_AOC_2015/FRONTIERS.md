# The Frontier Map — gaps the climb has named

**Contract:** this is an INDEX, not a backlog. Every entry points at
executable truth — a red pin, or a `.kz` frontier-ledger facet beside a green
day. An entry exists because code exists that states the gap; when the gap
closes, the SAME commit rewrites the day files toward the pure-`.k` form
(the covenant: all days stay VALID and green at every moment, and get more
elegant as the language improves — facets shrink, never break). Delete the
entry when the last pointer greens or empties.

A gap-closing session starts here: pick an entry, read its pointers, close,
rewrite the ledgers, delete the entry.

---

## 1. Regex GROUP captures
**What:** pattern branches bind only the whole matched text (cut-1 full
match); `(?<l>\d+)x(?<w>\d+)x(?<h>\d+)` cannot yet deliver its three numbers.
**Design RATIFIED (2026-06-12):** NAMED groups only (`(?<name>...)`; bare
`(...)` stays non-capturing structure — positional captures are
unrepresentable, killing the silent-transposition trap). The pattern is the
branch's PAYLOAD SCHEMA (the transform owns the pattern's semantics).
Delivery via the now-LANDED general shape-destructure at the binding
position: `| \`(?<l>\d+)x(?<w>\d+)x(?<h>\d+)\` { l: i64, w: i64, h: i64 } |>`.
Types in the destructure = checked assertions generally; match's splice
defines them as CONVERSION (the `0[i32]` move — dissolves text→int).
**Remaining build:** named-group parsing + TDFA span extraction in
regex_engine.zig (cut-2 restriction: no capture groups under quantifiers/
alternation — rejected loudly, same doctrine as backrefs) + match transform
emits the payload struct + typed conversion in the splice.
**Landed substrate:** destructure pins 020_016..020 (flat/nested-host/
effect-branch/KORU100-per-field/KORU101).
**Retires:** `parse-dims` in BOTH day-2 ledgers.
**Blocks forward:** day 6 (`turn on 0,0 through 999,999`), 7 (wire
expressions), 9/13/14/16 (sentence-shaped lines) — most parsing days.
**Pointers:** `810_021_day02_part1/input.kz`, `810_022_day02_part2/input.kz`.
**Owner thread:** the regex branch (matched-text binding + bound-path A/B
already landed there).

## 2. The STORE (collections / multi-cell)
**What:** no Koru surface for a set/map/growing collection; capture is
single-cell. Day 3 keeps its visited-set behind host events.
**Design open:** the parked multi-cell question — cell routing for nested
captures (none / field-name / binding-qualified) and/or a dedicated
collection-cell surface. The leak meter + `string.kz`'s phantom-ownership
String are the enforcement substrate waiting underneath.
**Retires:** `visit`/`house-count` in the day-3 ledger.
**Blocks forward:** day 3 part 2 (two santas, one shared set), 6 (1000×1000
grid), 7 (wire map + memoization), 9 (distance table), 13/21+.
**Pointers:** `810_031_day03_part1/input.kz` ledger; RED pins
`320_034_capture_nested`, `320_036_capture_nested_qualified`,
`320_038_capture_binding_qualified`.

## 3. Char/value DISPATCH surface
**What:** dispatching on a value (a char) needs a host proc with a switch
(`classify`); the natural Koru spelling wants match-on-chars or a
branch-on-value form.
**Retires:** `classify` in the day-3 ledger.
**Blocks forward:** day 8 (escape scanning), 10 (look-and-say), 12, 18 —
any per-char state machine.
**Pointers:** `810_031_day03_part1/input.kz` ledger.

## 4. String OPERATIONS (on the ownership spine)
**What:** `string.kz` has the lifecycle (phantom `String<view|instance>`,
take/release/free — enforcement pins 610_003..006 GREEN) but zero
operations: no split, no parse-int, no contains/indexOf.
**Design note:** text→int may dissolve into typed group payloads (gap 1)
rather than a standalone parse event — decide there first.
**Blocks forward:** day 4 (hex formatting), 5 part 2 partially, 8, 10, 11.
**Pointers:** `koru_std/string.kz` (the spine); RED pin
`610_007_reject_dangling_slice` (the borrow rule the ops will need).

## 5. Day-1 enablers from the charter (still unbuilt)
**What:** effect-shape `read-lines` (`! line l` via the for/each engine,
`| done n`, `| failed e`; namespace open: `std/fs:` vs `std/io:file.*`) and
the args FLAGS layer. Statement examples inline as consts so far — real
puzzle inputs (gitignored, local) need file reading the moment we run them.
**Blocks forward:** running ANY day against a real personal input.
**Pointers:** charter (`project_aoc_2015_charter` memory); `koru_std/fs.kz:13`
(the old array-shape read-lines).

## 6. Long-horizon tensions (named, not blocking)
- **Target-neutral expressions:** `c == '('`, `pos.y + 1` are Zig-flavored
  leaves; the legal-gap doctrine covers Zig-target runs. The layered
  expression-lowering design is the standing answer.
- **Kebab bindings in host expressions:** unspellable (`-` is a minus there);
  bindings that feed expressions want single words. Pinned in the
  320_036/038 headers. May want a rule or a rename convention.
- **MD5 (day 4):** wants a `std/crypto` stdlib event — a stdlib leaf, not a
  language gap; first taker writes it.
