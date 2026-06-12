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

---

## 1. Regex GROUP captures — CLOSED 2026-06-12
**Was:** pattern branches bound only the whole matched text; sentence-shaped
lines needed a host parse proc per day.
**Now:** NAMED groups (`(?<name>...)`; bare `(...)` stays non-capturing —
positional captures are unrepresentable, killing the silent-transposition
trap). The pattern is the branch's PAYLOAD SCHEMA: groups deliver through
the shape-destructure at the binding position, a TYPE on a field is
CONVERSION at the splice (text→int dissolves), and a plain binding takes
all groups as one struct of text slices. STRICT 1:1 both ways, enforced by
the transform (it owns pattern AND destructure at the same site); unwanted
capture = spell it `(...)`. Cut-2 doctrine: groups under quantifiers or
alternation rejected loudly (`GroupUnderQuantifier`/`GroupUnderAlternation`
— no single span exists, same doctrine as backrefs). Engine: Pike VM over
the tagged NFA (the RE2 captures design) — linear-time, zero backtracking,
ReDoS-immune WITH captures; binding-presence picks the engine (grouped
patterns compile the tagged VM, predicates keep the pure DFA).
**Green acceptance set:** 640_005 (dims flagship, typed conversion),
640_006 (whole-payload binding), 640_007..010 (1:1 both ways, quantifier/
alternation rejection, discard rejection).
**Retired in the same commit:** `parse-dims` (day 2 both parts),
`parse-reindeer` (day 14p1), `parse-pos` (day 25) — all four days now
PURE `.k` with empty ledgers.
**Still to harvest:** the parse procs in days 6/7/9/13/14p2/15/16/19p1/21
(each also waits on store/search for its OTHER procs — shrink, not flip).

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

## 5. Mock machinery × effect branches
**What:** mocking an event that declares effect branches emits the effect as
a result-switch arm; the Output union (correctly) holds terminals only, so
Zig rejects the phantom arm. The real path is fine — effects are handler
CALLS during the proc, terminals return after.
**Pointers:** RED pin `395_009_cross_module_mock` (header has the analysis).
**Note:** gap 5 (read-lines + args verticals) CLOSED 2026-06-12 — effect-shape
`std/fs:read-lines` + `std/io:read-lines` (stdin twin), harness STDIN piping,
ARGS/STDIN/input.txt gitignore whitelists, zero-alloc argv. The args FLAGS
layer (`~std/args:int(flag: ...)`) remains future polish, unblocking nothing.

## 6. EFFECT LOWERING — CLOSED 2026-06-13 (cut 1)
**Was:** runtime events lowered effects by control inversion (proc calls
handler across a Zig namespace boundary) — the root of cells being
unreachable, resume values being special-cased, listeners having no story.
**Now:** effectful events compile to COMPLETELY INLINED, MONOMORPHIZED code
at each invocation site (Lars-ratified): proc body spliced into a labeled
block, effect calls become handler-body splices IN FLOW SCOPE, proc returns
become labeled breaks feeding the ordinary terminal switch. The rule:
**scope-coupled (effects) → inlined by construction; value-coupled
(subflows/terminals, with their declared contract) → own frame, machine-
inlined when profitable.** Recursion of effectful events: rejected by
ruling. Discipline: inline-portable proc bodies (params + effect names +
`std.` + spine fns; __koru-prefixed locals — they share the consumer frame).
**Green acceptance set:** 650_001..006 (incl. four-level nesting and
subflow-in-effect-branch), 400_070/073/079/096. Census 641/42, zero
collateral.
**Cut-2 remainders (legacy call path until then):** resume-typed effects,
guard-grouped handlers, variant invocations, label loops, mock impls
(395_009 pin). The legacy path dies when the last migrates.

## 7. Toolchain pins from the full-calendar climb — CLOSED 2026-06-12
Three compiler bugs found and pinned during the 25-day grind, never
circumvented; all three greened in the gap-closing session and the
workaround ledgers were rewritten in the same commit:
- **210_123 GREEN** — label anchor on a subflow RHS panicked koruc. Root:
  `lexer.withoutLabelAnchor` chopped at the last `#` without validating a
  label followed (pre-invocation `#loop` truncated the invocation to "").
  Fix: validated strip + `parseSubflowImpl` extracts a leading `#name`
  into `Flow.pre_label` + the subflow emitter routes pre_label folds
  through `emitFlow` (the same state-loop lowering as top-level).
  **Loops came home:** day 4 (both), day 11, day 20 (both) now fold in
  Koru; their hosts shrank to single-check leaves.
  (The pin's own spelling needed correction first — it died on PARSE003
  before reaching its panic. The caveat protocol worked as designed.)
- **210_124 GREEN** — `<` in an if condition dropped the whole argument.
  The mechanism guess (phantom-angle scan) was WRONG: `lexer.parseArgs`'s
  generics angle-tracking left `angle_depth` stuck on an unmatched `<`,
  so the comma-split never fired. Fix: `<` opens an angle group only when
  it hugs an identifier AND a string-aware lookahead finds a matching `>`.
  Day 12p1's nested-if workaround collapsed to `ch >= 48 and ch <= 57`.
- **640_004 GREEN** — the 9-alternation BufferOverflow was the emission
  CodeEmitter's FIXED 256KB buffer; it now grows on demand (initGrowable —
  generated code has no size ceiling). The 676-branch encoding still
  exceeds the engine's deliberate state cap, but the failure is now LOUD
  and NAMED at the match site: `regex: cannot compile pattern ...:
  DfaTooLarge` (the bogus-KORU100 surface died with a one-line
  `@errorName` fix in koru_std/regex.kz). Day 5p2's pure form now waits
  on an engine strategy for huge alternations (lazy DFA / NFA
  simulation) — a real frontier, not a bug.

## 8. SEARCH / RECURSION (permutations, subsets, backtracking)
**What:** no Koru spelling for recursive search — permutations (days 9/13),
subset enumeration (days 17/24), loadout product-walk (day 21), greedy
reverse rewriting (day 19p2), recursive eval with memo (day 7). Every one
is a host proc today. This was the SECOND-biggest dependency in the ledger
census (11 facets) and had no entry — named 2026-06-12 during the
pure-Koru inventory.
**Design open:** §6 ruled recursion of effectful events REJECTED (inlined
by construction), so the answer is not "just recurse an event." Candidate
shapes: subflows with own frames are value-coupled and CAN recurse (the
§6 rule names the split); a label-fold over an explicit work stack (the
store frontier feeds this); or a dedicated search/enumerate stdlib surface
(effect-shape like read-lines: `! candidate c |> ...`, engine in the
stdlib). Likely entangled with gap 2 — a work stack IS a collection.
**Blocks forward:** days 7, 9, 13, 17, 19p2, 21, 24 — after store, this is
what stands between the calendar and pure `.k`.
**Pointers:** the `← host`/`← host recursion`/`← host search` lines in
those seven days' ledgers.

## 9. Long-horizon tensions (named, not blocking)
- **Target-neutral expressions:** `c == '('`, `pos.y + 1` are Zig-flavored
  leaves; the legal-gap doctrine covers Zig-target runs. The layered
  expression-lowering design is the standing answer.
- **Kebab bindings in host expressions:** unspellable (`-` is a minus there);
  bindings that feed expressions want single words. Pinned in the
  320_036/038 headers. May want a rule or a rename convention.
- **MD5 (day 4):** wants a `std/crypto` stdlib event — a stdlib leaf, not a
  language gap; first taker writes it.
- **Multi-line `const { }` with nested braces in values:** the multi-line
  source-block line-collector stops at the first standalone `}`, so an array
  literal value can't span lines (day 5 single-lines its sample list as the
  workaround — see the comment in `810_051_day05_part1/input.k`). Wants the
  brace-depth-aware collector treatment.
