---
challenge: diagnostic-site-audit
kind: frame
status: standing
yields: verified diagnostic-site defects in one audited emission family, each pinned by a test or a fix — and a ledger row for every site read, clean ones included
family: toolchain
created: 2026-09-12
---

*Walker context — the recurrence that earned this frame. On 2026-09-12 Lars used
the toolchain as a human for under forty minutes and hit cracks in the first
two. One `frames(win: w, count: 30)` call, three errors, four defects:*

```
- kind-blind: a missing `!` arm was told "no continuation found" — the
  remedy it spells is `|`, which walks the user into KORU025 kind-mismatch
- where: all three errors pointed at the [with] flow head, line 4 — the
  offending call is line 7; the caret names an ancestor, not the fault
- arity: one fault, three reports — an aggregate "branches are not handled"
  plus the two per-branch errors it subsumes
- never-false: the same aggregate fired when every declared branch was
  optional — an error with no fault behind it
```

*The pilot that followed read ~110 `addError*` emission sites in
`shape_checker.zig` + `flow_checker.zig` against five questions and produced
**5 location fixes, 1 wording-drift finding, and 1 latent false-positive
killed** — in a single pass, over two files, in one session.*

***The suite carries ~200 diagnostic emission sites and they are read only when
a user trips on one.*** *The board mines what is red. `018` mines the green from
the user's side — compile a program, report what was odd. `021` mines the green
from the machine's side — read what the compiler ships. **This frame reads the
machinery itself:** the call sites that produce every diagnostic, audited
against a fixed lens. The user finds quirks one at a time; the emission-site
audit finds the *class* the quirk belongs to — today each quirk traced to a
site-level pattern (inherited location, kind-blind vocabulary, aggregate
double-report), not a one-off bug.*

---

## The brief (sealed — you are the contestant)

**Pick an emission family and read every diagnostic site in it, against the
lens.** Not behavior — that is `018`'s faucet. The *sites*: each `addError`,
`addErrorAtLocation`, `reporter.addError*` call in the files you take. Enumerate
them first; an audit that samples is a stroll.

An emission family is a shardable slice: one checker's diagnostics
(`shape_checker.zig`'s remaining sites), one organ (`parser.zig` parse errors,
`auto_discharge_inserter.zig` obligation errors), one code (`every KORU030
site`), or one surface (CLI messages, crash reports). Declare the family's
boundaries before you start and count its sites — the ledger needs a denominator.

For each site, answer **the five questions**:

1. **where** — does the caret land on the thing the user must change, or on an
   ancestor? The fault has an owner; the location must name it. `cont.location`
   and `proc.location` exist — sites that pass the flow head instead are the
   day's most common defect.
2. **what kind** — does the message use the declaration's kind vocabulary? An
   effect `!` is not a terminal `|`; the missing object is a *handler*. A
   message that names the wrong kind teaches the wrong remedy.
3. **arity** — does one fault produce one diagnostic? Aggregates that re-report
   what specific errors already say are double reports; errors that fire in
   packs where one carries the fault are noise.
4. **remedy** — does the message teach the spelling or action required? "no
   continuation found" does not tell a user to write `! frame f |>`.
5. **never-false** — can the diagnostic fire when nothing is wrong? Read the
   guard. All-optional branch sets, empty continuations, wildcard decls —
   the false positive lives where the check forgets a carve-out.

Return **a ledger, not a highlight reel**: every site in the family, marked
defect / clean / drift / needs-ruling. Clean rows count — "audited, no finding"
is a result the next replay builds on.

## The finding class this frame wants

Rank by this ladder:

1. **Never-false positives.** An error that fires with no fault behind it —
   the worst diagnostic is the one that cries wolf on a correct program.
2. **Carets on ancestors.** The error names line N but the fix belongs at
   line N+k; the user edits the wrong place and learns the wrong lesson.
3. **Kind-blind remedies.** The message spells a fix the kind system will
   refuse — effect told as continuation, terminal told as handler.
4. **Duplicate and aggregate reports.** One fault, N errors; or an aggregate
   beside the specific errors that subsume it.
5. **Wording drift across passes.** The same rule with two sentences —
   shape says one thing, flow another. The diagnostic registry has one
   meaning; two wordings is a second wall waiting to drift.
6. **Remedies that don't teach.** The message names the fault but not the
   spelling — where a hint or a `for example` line would.

## Ground yourself FIRST

**Read the site before judging the message.** The location passed, the guard
conditions, the fallback — the defect is in the plumbing, not the prose.
`location` inherited from a caller three frames up is the day's signature.

**Reproduce before you claim.** A defect you did not trigger is narration —
write the smallest `.kz` that fires it, read the caret, then call it a finding.
`unmeasured` is not a finding.

**The arm owns the error.** When the diagnostic is about a specific
continuation, proc, or arm, its `location` field is the honest caret —
`cont.location`, falling back to the call site only when `line == 0`. This
is the established convention in the same files; sites that ignore it are
the defect.

**A finding is the pin, not the observation.** For every confirmed defect the
deliverable is the fix + the regression test that would have caught it, or a
recorded reason it can't be pinned. And an honest answer to *why the board
did not* — name the category of blindness.

## ⚖️ Make a qualified guess, never a verdict

Same stance as `018` and `021`. Two readings, and they are not yours to choose
between:

- **(A) the site is wrong** — a real defect in location, kind, arity, or
  remedy.
- **(B) it is deliberate** — a broad location is the only honest one (the
  fault genuinely has no narrower owner), the aggregate is the user's first
  summary, the wording is pinned by an intentional contract.

Write **both**, then lean with confidence: `grounded` (you cite the site, a
repro, a pin) is the only level where a hard lean is allowed; `inferred` is
reasoning without a citation; `unsettled` is a frontier — often "the message
is right but which location is honest needs a ruling" (today's column-0 and
per-link chain locations are exactly this: they need parser provenance, which
is a design call, not a fix).

⛔ **Do not flatten diagnostics to silence the audit.** If a broad location is
honest (the fault owns the whole flow), say so — do not move carets to look
busy. A `cont.location` slapped on a flow-level verdict is its own defect.

## Known territory, already claimed — do not re-mine

- `shape_checker.zig` + `flow_checker.zig` branch-coverage sites: audited
  2026-09-12, fixed in `fa026be34`. KORU021/028/030/101 arm-level locations,
  KORU022 kind-aware wording, KORU040/arm-fire step locations, when-clause
  location threading, aggregate dedup. Read the commit, not the old state.
- Obligation/phantom diagnostics in `phantom_semantic_checker.zig` +
  obligation/auto-discharge diagnostics in `auto_discharge_inserter.zig`:
  audited 2026-09-12, ledger below. Arm-owns-the-error threading landed
  (`cont.location` with line-0 fallback through `validateContinuation`,
  `validateContinuationAsVoidChain`, `validateNamedBranchRecursive`,
  `checkContinuation`, `checkForeachBranchContinuation`,
  `insertDisposals`, `insertDisposalsInForeach`, `creditConsumingArgs*`),
  decl-coordinate translation at KORU033/040/083, `_auto_N` display fix,
  dup-proto prose lines via `userLineIn`. Pins: 330_127–330_132.
- Per-link chain locations: traced to `stitchPipeChainLines` flattening —
  every `|>` link inherits one `chain_location`. Needs parser provenance
  (a design call on `parser.zig`), not another audit.
- **Two coordinate systems, one trap.** AST-decl locations
  (`getUserDeclStartLocation` — EventDecl et al.) are stored in USER
  coordinates because `--ast-json` consumers read them raw (210_164 pins
  this). `addError*` stores PARSER coordinates and `classifyLine`
  subtracts the injected prelude at render. Any site that hands a decl
  location to `addError*` double-subtracts — caret lands one line early,
  `:0` for a line-1 decl. Sites in future families: check which
  coordinate the location field is stored in before trusting it.
  Prose-embedded line numbers must go through `userLine`/`userLineIn`.
- KORU050/021 two-wordings drift: logged, wants a shared `errors.zig`
  helper or a ruling.
- `src/parser.zig` diagnostic emission sites: audited 2026-09-12, ledger
  below. The parser's off-by-one convention trap (`self.current` is a
  0-based index that means "the line" once incremented, and "the previous
  line" before) produced two mirrored defect classes — carets one line
  early (`current - 1` where `current` was already the 1-based line) and
  one line late (`current + 1` in the same position). 40 emission sites
  re-coordinated plus five `+1`-helper caller args and one entry-captured
  anchor; one empty-name refusal added (`@` alone used to compile). 19
  new pins (210_219–210_237), five stale expected-files re-pinned.
  `lexer.zig`/`flow_parser.zig` have no direct emissions — declared out
  of family (ledger below for the boundary ruling).
- `src/shape_checker.zig` remaining (non-coverage) emission sites:
  audited 2026-10-29, ledger below. One pack-firing defect fixed (the
  record-fire missing-field loop asserting speculative absences beside an
  unknown-arg refusal — pins 400_225/400_226). `validateEventTap` +
  `validateTapContinuations` confirmed dead: nothing produces
  `.event_tap` items since `parseEventTap` was removed and `~tap` became
  a transform. The pilot's branch-coverage sites were re-read, not
  re-charged.

## What "done" looks like

- The family declared, its sites enumerated and counted.
- A ledger: every site → defect / clean / drift / needs-ruling, with the
  five questions answered for the defects.
- For each defect: the repro, the fix or the ruling request, the pin, and
  the category of blindness.
- The ledger appended to this file's history (or the catalog), so the next
  replay knows the audited frontier — a family fully read is exhausted
  until the code moves.

## Failure modes

- **Sampling instead of enumerating.** "I looked at some sites" is not an
  audit. Count the family first.
- **Judging messages without reading guards.** The never-false check lives
  in the condition, not the string.
- **Reporting without reproducing.** A site that *looks* wrong but you
  never fired is a guess, not a finding.
- **Moving every caret narrower.** Some faults honestly own the whole
  flow — over-precise carets are a defect class too.
- **Re-mining audited ground.** Read the claimed-territory list; spend the
  replay on unclaimed families.
- **Calling drift a defect without checking which side is canonical.** Two
  wordings means one is right; find the pin before filing.

---

## Ledger — 2026-09-12 — obligation/phantom family (worktree `diag-023-oblig`, base `216ae42e9`)

**Family boundaries.** Every `self.reporter.addError*` emission call in
`src/phantom_semantic_checker.zig` (obligation tracking, phantom-state
argument validation, polarity, stale-read, scope/conservation walls) and
`src/auto_discharge_inserter.zig` (auto-discharge candidate selection,
scope-exit walls, outer-scope discharge, call-site arity, `[!]`-default
shape, strict panic-branch). Non-emitting calls (`hasErrors`,
`printErrors`) excluded. **Denominator: 47 sites — 27 checker + 20
inserter.**

### Defects found — all `grounded` (site + live repro + pin)

**D1 — Decl-coordinate double-subtract (the family's worst defect class,
ladder rung 2: caret on the wrong line entirely).**
`parser.getUserDeclStartLocation` stores `EventDecl.location` in *user*
coordinates (deliberate: `--ast-json` reads stored locations raw, pinned by
210_164), but `addError*` treats stored lines as *parser* coordinates and
`classifyLine` subtracts the injected prelude line at render — so every site
that hands a decl location to `addError*` renders one line early: onto the
blank line above `~tor`, or `:0` when the decl sits on line 1.

- Sites: checker 754/767 (KORU033 issue/consume polarity), 779/801 (KORU040
  unknown phantom module, concrete + union-member arms); inserter 3288→3297
  (KORU083 `[!]` on non-void tor). All five reachable through
  `validatePhantom`'s six `event_decl.location` callers.
- Repro: `~tor mk { bad: *Handle<owned!> }` on line 4 → caret `:3:0` on a
  blank line; on line 1 → `:0:0`. After fix: the `~tor` line.
- Fix: translate user→parser coords at the diagnostic site
  (`line + injection_line_count`, same-file guarded) — inside
  `validatePhantom` once for all four checker sites; inline at KORU083.
- Pins: `330_130_polarity_diagnostic_names_the_tor_decl` (KORU033),
  `330_132_default_discharge_annotation_names_the_tor_decl` (KORU083).
- Board blindness: **location-blind pins.** Existing EXPECTs assert message
  text only (`CONTAINS`); no `ERROR_AT` existed anywhere in the obligation
  clusters, so a caret on a blank line stayed invisible. Also a
  **coordinate-scheme trap**: two line-number spaces coexist in the AST and
  only render-time translation separates them — nothing type-level marks
  which space a `SourceLocation` is in.

**D2 — Inherited flow-head location through the whole continuation walk
(ladder rung 2).** `validateContinuation` threaded the caller's `location`
(flow head) into every nested call, so every continuation-specific
diagnostic — unknown branch, arg mismatch, use-after-discharge, stale read,
missing tracked binding, hard-terminal leak, label-jump conservation —
pointed at the flow head regardless of which arm owned the fault.

- Sites: checker 1895/1911 (`reportLeaksAtHardTerminal`), 2234, 2695/2713,
  2918 (`validateContinuationAsVoidChain`), 3038 (label jump), 3300/3313,
  3365/3409 (`reportStaleReads`), 3484–3849 (ten `validateArgument` sites)
  — all consumed a `location` param that was always `flow.location` at root
  and never re-derived per arm, despite `ast.Continuation.location` existing.
- Repro: `| good g |> peek(h: g)` arm leaking `<owned!>` on line 37 → caret
  `:36:0` on the flow head; `use-file` after `close` → UaD at flow head.
  After fix: the arm's own line.
- Fix: `const location = if (cont.location.line != 0) cont.location else
  caller_location` in `validateContinuation`,
  `validateContinuationAsVoidChain`, per-cont in
  `validateNamedBranchRecursive`, and `nested.location` for the nested-arm
  fallback loop — one-line derivation per frame, convention copied from
  `fa026be34`.
- Pin: `330_127_arm_owns_obligation_leak` (checker hard-terminal leak at the
  arm; `--auto-discharge=disable` so the wall, not the inserter, is under
  test — same staging as 330_122).
- Board blindness: same location-blind-pin category; the arm convention was
  established for shape/flow checkers but nobody re-checked whether the
  obligation checker had adopted it — **adoption-gap blindness**: a fix
  landed in one family and its twin file was assumed fine.

**D3 — Label jump names compiler-minted `_auto_N` (ladder rung 3-adjacent:
the message names an object the user never wrote).**
`| again _ |> @loop()` discards the payload; the inserter renames `_` to
`_auto_0`, and the KORU030 conservation diagnostic printed that synthetic
name — unactionable and unreadable. Also inherited the D2 location defect
(caret on a blank line past the jump).
- Site: checker 3038 (was 3002 pre-fix).
- Repro: `330_075`'s own input — caret `:31:0` on a blank line, message
  named `_auto_0`. After fix: `:36:4` on `| again _ |> @loop()`, naming
  `input:*Handle` (the binding's declared base type — the same display rule
  `reportLeaksAtHardTerminal` already applies to `_auto_N` and `s.field`
  paths).
- Fix: site replicates the established display-name rules (dot-suffix strip,
  `_auto_` → `base_type`).
- Pin: `330_128_label_jump_names_arm_and_source_binding` — `ERROR_AT` +
  `NOT_CONTAINS _auto_`.
- Board blindness: **text-pin blindness** — `330_075`'s EXPECT asserted
  `CONTAINS "drops cleanup obligation"` only; both the blank-line caret and
  the synthetic name were invisible to it.

**D4 — Inserter obligation diagnostics at `flow.location` (ladder rung 2).**
Every inserter wall that names a continuation-owned fault reported at the
flow head:

- `insertDisposals`/`insertDisposalsInForeach` (3188/3202/3218, 2923/2931/2947):
  "not discharged / Call one of / multiple discharge options" — the leaking
  continuation's exit owns it → `cont.location`.
- `creditConsumingArgsForDecl` (3092 KORU032 outer-scope discharge; 3114
  field-path double-discharge): the invocation's arg owns it → threaded
  `site_location` through `checkInvocationSatisfiesObligations`/
  `creditConsumingArgs` from the enclosing `cont`.
- Scope-exit walls (1722/1730/1748 on `cont`; 2566/2574/2590 on a
  `NamedBranch`): `NamedBranch` carries no location — nearest honest caret
  is `branch.body[0].location` (the `! each` arm's first line).
- Repros: `repro_scope.k` KORU032 `3:0`→`7:4` (the `! each` arm);
  `repro_scope_amb.k` ambiguity `3:0`→arm line.
- Pins: `330_129_scope_discharge_names_the_arm` (KORU032),
  `330_131_scope_exit_ambiguity_names_the_arm` (multiple-options at
  scope exit).
- Board blindness: adoption-gap + location-blind pins, as D2.

**D5 — Duplicate-identity prose line numbers in parser coordinates
(ladder rung 5, wording drift inside one message).** The caret at
`site.location` was correct, but the prose embedded `site.location.line` /
`prior_loc.line` raw — the "declaration at file:N" the user read was off by
the prelude height (1).
- Sites: checker 251/262 (`registerDeclaredIdentity`, KORU030 dup
  foreign/proto).
- Fix: `userLineIn` on both embedded numbers — exactly what
  `errors.zig:293`'s doc prescribes for prose-named lines.
- Pin coverage: existing 665_003 / 660_029 / 660_031 / 667_002 pins assert
  the prose shape (`CONTAINS collides with the prior registration`) and all
  still pass; a dedicated line-number pin would need a bespoke `~proto`
  collision repro — recorded here as fixed-and-verified-by-neighbor rather
  than separately pinned.
- Board blindness: **prose-blind pins** — expectations match message text
  loosely enough that a wrong embedded line number reads identical.

### Clean sites (verified — deliberate location or correct arm already)

- Inserter 1144 (KORU080 missing required input): already threads
  `cont.location` per-continuation (line ~1097) — the convention existed in
  this file and D4's sites ignored it.
- Inserter 1237 (KORU112 bare module-scope ref): `proc.location` — the proc
  owns the fault.
- Inserter 1905/1913 (flow-level silent-drop audit): `flow.location` is the
  honest caret — the binding is by construction absent from every arm; the
  audit is a property of the whole flow exit.
- Inserter 4914 (KORU022 strict panic branch): `flow.location` — the missing
  handler is absent, nothing narrower to point at.
- Checker 2234 unknown-branch and all `validateArgument`/`reportStaleReads`/
  `validateEventContextPhantom`/`validateSingleInvocation` sites (3313,
  3365, 3409, 3484–3849): were D2-defective by inheritance, now arm-correct;
  wording/kind/remedy already sound (state names, `Call one of:` lists,
  parameter names).

### needs-ruling / unsettled

- **Per-link precision inside a chain.** A UaD on the *second* `|>` link of
  an arm reports at the arm's start (column of `|`), not the offending link
  — e.g. `repro_nested.k` fires at `3:4`. Correct line, wrong column-ish:
  needs per-link provenance from `stitchPipeChainLines` — already claimed
  parser-provenance territory, not re-litigated here.
- **`flow.location` initial binding at checker's 1608/1668**: the flow-head
  invocation's own args are judged at the head line — honest.
- **Aggregate arity**: `reportLeaksAtHardTerminal` can emit one diagnostic
  per leaked binding at one arm (observed: `h0` + `g`, two real faults) —
  that is N faults, N diagnostics, not double-reporting. Clean.

### Verified vs unverified

- `zig build` clean; all five+one pins green through `./run_regression.sh`
  with `KORU_STDLIB` pointed at this worktree (two targeted runs: 33/33 and
  12/12, `Running N tests` matched the request both times). Repro carets
  read from the live `zig-out/bin/koruc` built from this tree.
- Backend builds in this worktree still resolve `src/` through
  `/usr/local/lib/koru` (the main-checkout symlink — known phantom); the
  pinned assertions are all frontend diagnostics emitted by the worktree
  `koruc` snapshot the suite builds (`zig-out-run-*/bin/koruc`), so the
  verdicts stand. No backend-behavior claim is made.

## Ledger — 2026-09-12 — parse-diagnostic emission family (worktree `diag-023-parser`, base `00e2c6f3c`)

**Family boundaries.** Every diagnostic emission call in `src/parser.zig`:
`self.fail`, `self.failWithHint`, and direct `self.reporter.addError*`.
Counted by literal call-site scan at `00e2c6f3c`: **182 sites** (141
`fail`, 9 `failWithHint`, 25 `addError`, 4 `addErrorWithHint`, 3
`addErrorWithHintAndSpan`). The two remaining textual `fail(` matches are
the helper definitions at 791/799 — excluded. `src/lexer.zig`: **0**
emission sites — it returns typed errors (`UnbalancedArgs` et al.) that
the parser surfaces at its own sites (e.g. `parseArgsReported` 10789);
propagated errors are not emission sites. `src/flow_parser.zig`: **0**
emission sites — it returns `ParseErrorInfo{message,line,column}` records
surfaced by `koru_std/interpreter.*.kz`; error-return constructors are
declared OUT of this family (a separate family if wanted — its 0/0
"Empty input"/"No invocation found" coordinates are noted, unaudited).

**The coordinate system, measured.** `self.current` is a 0-based buffer
index; `addError*` take a 1-based parser line and `classifyLine` subtracts
the injected prelude. Two spellings are each correct in their own context:
while `current` still points AT the faulting line, the site passes
`self.current + 1`; after the line is consumed (`current += 1` already
ran) the site passes `self.current`, which then IS the 1-based line. The
defects are the sites that grabbed the wrong adjustment for their
context. Every verdict below was measured by compiling a minimal `.k`
repro against the worktree `koruc` and reading the rendered `-->` line —
no site was judged from the source expression alone.

### Findings (ladder-ordered: wrong location; never-false folded in where it rides)

**P1 — `self.current - 1` (or bare index) where `self.current` is already
the 1-based line: caret one line EARLY.** Fixed sites: `2935`
(`event_line_index` → `+1`, `[keyword]`-without-pub), `3312/3325/3342/3353`
(parseProcDeclWithAnnotations — `pub proc`, malformed, `=` syntax, missing
body), `10235/10260` (unterminated raw ` ` `/`[` names), `10322` (`->` in a
branch decl), `10373` (single-field record resume), `10386` (`-> T` +
same-line resume arms), `10444/10637` (invalid branch name, bare and
braced paths), `10713` (branch annotation missing `]`). Latent twins in
dead/defensive paths fixed by the same convention: `2502`
(parseEventDeclWithAnnotations "malformed tor" — unreachable, dispatch
pre-guards the prefix).
Repro class: `| chosen i32 -> i64` on line 5 reported `:4` (caret on the
`tor` header); `[keyword]tor …` on line 4 reported `:3` on a blank line.
Board blindness: the location-pinning `expected.txt` files had
*fossilized* the defect — `330_004` pinned `:3:1` with a blank preview
line, `510_023` pinned `:4:1` pointing at the `~tor` header. Both updated
to the fault line; the fix also makes them green against their own text.

**P2 — `self.current + 1` where `self.current` is already the 1-based
line: caret one line LATE.** Fixed sites: `7564/7590/7606/7749/7909/7979`
(parseBranchContinuationBase — quoted names, missing/invalid branch name,
`when` condition), `9229/9240` (parseConstructionStep), `9364/9375`
(parseConstructString), `9395/9406/9423/9438/9466/9475/9484/9496/9593/9637`
(parseBranchConstructorWithContext incl. `.{}` shorthand and the
field-purity wall), `10903/10919/11060/11089` (parseShape field loop —
missing type, digit name, `[]const u8`, multi-colon type ref). Caller-arg
twins where the callee adds `+1` internally: `5128`
`rejectDotNamespace(clean, self.current)`, `3377/3524`
`rejectSnakeName(…, self.current, "proc")`, `7746`
`rejectSnakeName(…, self.current, "branch")`, `10183`
`rejectDuplicateResumeArms(…, self.current)` — each now passes
`self.current - 1` (the line's index), matching the convention the other
callers use (`10440/10633` already passed `-1`; `rejectSnakeName` callers
in same-line contexts pass a true index).
Repro class: `| 9bad v |> show()` on line 9 reported `:10` (the line after
the continuation); `tor t { f }` reported the line after the decl;
`std.io:` reported the line after the invocation; a multi-line
duplicate-resume-arm block reported the line *past the last arm* (past EOF
on a file ending there). Worst measured: `=> ok { a: 1` unclosed at line 9
reported `:11` on a 9-line file.
Board blindness: same fossilization — `510_030`/`510_032` pinned `:5:1`
with a blank preview for a fault on line 4; `430_006` pinned the caret on
`| error e => error { e.message }` — an *innocent sibling arm* two lines
below the offending field. All three updated.

**P3 — implicit flow block guard: early caret + misclassification of the
close line (6628).** The `~`-required check inside `{ }` flow blocks fired
with `self.current` while `current` still pointed AT the offending line —
one line early. Fixed to `self.current + 1`. Residual wart, recorded not
fixed: the block close accepts only a bare `}`; a `}:` close lands in the
`~`-check, so a `}: name` attempt is reported as "Flows inside block must
start with ~" — true of the line, wrong about what it is. Whether `}:`
should be legal there is a language-shape ruling, not a diagnostic fix.
Pin: `210_234`.

**P4 — `-> T` + indented resume arms anchored at the last arm (10161).**
After `collectIndentedResumeArms` consumed the arm lines, `self.current`
named the line after the `!` decl — the caret landed on the first arm
while the complaint is about the `-> T` on the `!` line. Fixed by
capturing `effect_line = self.current` at function entry (documented why
in-source). Pin: `210_230`.

**P5 — dead guard + silent accept: `~@`/`@` with an empty name.**
`parseLabelDecl`'s "malformed label declaration" (11186) was unreachable —
dispatch guarantees the `~@` prefix — and the empty name it should cover
was silently accepted: `@` alone **compiled cleanly** (measured). Added
the `name.len == 0` refusal through the existing site. Pin: `210_237`.

### Verified clean (measured or convention-pinned by direct repro)

- Dispatch-loop sites (`current` AT the line, `+1`): `1145, 1172, 1527,
  1541, 1572, 1795, 2129, 2142, 5860, 7107, 11213, 11225` — `pub proc`
  `:4` (r01), stray `|` `:4` (u29), chain-splitting comment `:9` (u28),
  `part a.b` `:4` (u07).
- Decl-parameterized sites (`event_line_index + 1`, `error_line`,
  `tail_line`, `decl_line`, `start_line`, `line_index + 1`,
  `line_idx + 1`, `opening_line_idx + 1`, `report_line + 1`,
  `directive_line`): `1697, 1748, 1837, 1892, 2000, 2299, 2323, 2337,
  2346, 2374, 2403, 2449, 2529, 2566, 2635, 2666, 2717, 2751, 2800, 2846,
  2955, 3008, 3028, 3042, 3064, 3132, 3175, 4032–4192` — includes the
  same-line `tor {} | a | b` branch loop where `event_line_index` IS the
  branch's line (u02 verified `:5`).
- Continuation/step `self.current` sites (already the 1-based line):
  `7640, 7650, 7665, 7705, 7792, 7845, 7858, 8815, 9150, 9194, 9618,
  10128, 10138, 10202, 10429, 10464, 10557, 10659, 10823, 10836, 10881,
  10789` — the `+1`/`current`/`−1` asymmetry inside one function was the
  fingerprint: `9618` punning fired correct at `:9` while its `+1`
  siblings landed on `:10`; `t20`/`t21`/`t23`–`t26`, `u08`–`u10`, `u12`.
- Invocation `self.current` sites (`current = head_index + 1` → head
  line): `925, 941, 4314, 4673, 4743, 4906, 5132, 5223, 5248, 5263, 5321,
  5399, 5526, 5660, 5681, 5908, 5937, 5975, 6404, 8568, 8580, 10789` —
  `pick(x: 1 |` `:8:10` (u26), unclosed `@"` `:8` (u33), missing file `:8`
  (u34), `>"path"` missing scope `:8` (u35).
- `location.line`/`location.line - 1` sites: `7271, 7320, 8257, 8568,
  8580, 8971, 8984` — `location` captured as `getCurrentLocation()` while
  `current = index + 1`, so `line - 1` is the head line (u08, s14, s17,
  u33, u34 verified).
- `line`-parameterized helpers where callers pass `self.current` raw:
  `1079` checkRedundantPunning → `t19` verified `:8`; `9118` same.
- Source-search relocators `9833, 9865` (KORU033/KORU035): deliberately
  scan `self.lines` for the offending text — the convention this family
  needed elsewhere.
- EOF/`self.current`-at-end sites (`2075, 2461, 3112, 3273, 3445, 4568,
  4612, 5873, 6370, 6389`): render the last line — honest for
  "unexpected EOF".
- Claimed-family sites not re-judged: `9899, 9918, 9938` (KORU027
  obligation discharges — audited in the obligation/phantom ledger).

### Dead / unreachable sites (recorded, not charged)

- `parseEventDecl` (3112/3132/3175) and `parseProcDecl` (3445/3463/3500):
  no callers — dead functions; their `self.current` args are
  coincidentally correct.
- `2502, 3312, 3325`: defensive `else` branches behind dispatch prefixes
  the caller already proved — unreachable; convention-fixed anyway.
- `9395` "expected '{' in branch constructor": callers only route `{`
  -bearing content — latent.
- `6748` (`}:` close with no bind name, `self.current` → `+1` by
  convention): probes `}:`/`}: |>` both routed to the earlier bind-name
  site `5248` instead; fixed latently, unreached in measurement.

### needs-ruling / unsettled

- **Stitch-drift residual.** Where the fault is inside a multi-line
  stitched construct, `self.current` now names the last line of the
  construct (e.g. `430_006` re-pinned `:19` for a field on `:18`; `u16`
  unclosed `{` still lands past EOF at `:10`). Per-field/per-link
  provenance through `stitchPipeChainLines` is already claimed territory —
  not re-litigated.
- **`|` payload-first message choice.** `| { f: i32 }` fires
  `invalid branch name ''` (10637) rather than `branch missing name`
  (10429) — the empty-name wording is degenerate but the caret is now
  right. Cosmetic; a wording ruling can fold it later.
- **`}:` close in implicit flow blocks** — see P3.
- **flow_parser `0/0` coordinates** — declared out of family, recorded
  for whoever claims returned-error diagnostics next.

### Verified vs unverified

- `zig build` clean in the worktree; all repros run against
  `zig-out/bin/koruc` built from THIS tree with
  `KORU_STDLIB=<worktree>/koru_std`. Every reported `-->` line in the
  findings was read from rendered output, twice (before and after fix).
- `./run_regression.sh` targeted: **23/23** new+re-pinned tests pass
  (`Running 23 tests` matched the request), then **40 pass / 4 TODO /
  0 fail** on the control set — all existing `ERROR_AT` and message pins
  in the parser cluster, plus `210_201` (already green from `df8533b3c`;
  its aspirational header is stale, untouched here).
- Worktree backend caveat observed live: a foreign `zig build`
  (`/Users/larsde/src/kopium` backend) was running during one rebuild,
  resolving `-Mkoru_parser=/usr/local/lib/koru/src/parser.zig` — the main
  checkout. It read main's tree, not this one; my edits could not reach
  it. All pinned assertions are frontend diagnostics from the worktree
  `koruc` — no backend-behavior claim is made.
- Full board NOT run (per challenge rules — targeted subsets only).
  `test-results/unit-tests.json` restored after filtered runs.


---

## Ledger — 2026-10-29 — shape_checker.zig remaining sites (worktree `023-the-diagnostic-site-audit`, base `9f8576850`)

**Family boundaries.** Every `self.reporter.addErrorAtLocation*` emission call
in `src/shape_checker.zig` outside the pilot's branch-coverage set
(`fa026be34`: KORU021/022/028/030/040/101 coverage sites, kind-aware KORU022
wording, chain-link `step_loc`, aggregate dedup), plus one
`errors.branchKindMismatch` helper call. The pilot's sites were re-read for
context but not re-charged. **Denominator: 55 sites** (54 `addErrorAtLocation`
{,WithHint} + 1 `branchKindMismatch`). `ShapeChecker` runs in the backend's
`check-structure` pass (`koru_std/compiler.kz:2106`) on the serialized AST —
live code, but reachable only through `--deep-check` or a full build; `koruc
-c` is frontend-only and cannot see any of these sites fire.

### Findings (ladder-ordered)

**P1 — Speculative second-pass diagnostics: the missing-field loop asserts
absences the unknown-arg refusal already made unknowable (ladder rung 4 arity,
never-false-adjacent).**
`validateArmFire`'s record-payload block ran two independent passes over
`inv.args`: the unknown-arg loop (KORU021/KORU030) then an unconditional
missing-field loop (KORU022 per absent field). Measured: `pair(wrong: 1)`
against `! pair { a: i64, b: i64 }` produced **three diagnostics at one
caret** — `KORU021 no payload field 'wrong' (fields: a, b)` + `KORU022 'a'
missing` + `KORU022 'b' missing`. The KORU021's own field list already carries
the missing information, and the "missing" claims are speculative — `wrong`
may be a misspelling of `a`, in which case `a` is not missing at all.
- Fix: `unknown_arg` flag; the missing-field loop runs only when every arg
  resolved. `pair(wrong: 1)` → 1 diagnostic; `pair(a: 1)` → `b` missing
  (unchanged); `pair()` → per-field reports (unchanged, see needs-ruling).
- Pins: `400_225_effect_record_fire_unknown_arg_no_pack` (CONTAINS KORU021 +
  `NOT_CONTAINS missing at the firing site` + `ERROR_AT`), and
  `400_226_effect_record_fire_missing_field_reports` (the preserved half —
  clean args still report the absent field).
- Board blindness: **zero message pins on the whole firing-site family.** No
  `CONTAINS`/`ERROR_AT`/`expected_error.txt` anywhere covers the arm-fire
  KORU021/022/030/102/130/131 diagnostics — 400_149/150 pin stage only. A
  3-for-1 pack at a correct caret was invisible to the board.

### Verified clean (guard read; the marked ones also live-repro'd)

- `validateArmFire` remaining sites (1015, 1032, 1037, 1055, 1057, 1075,
  1091, 1100, 1111, 1120, 1125): the `location`/`cont.location` split is
  deliberate — faults owned by the fire call (payload arity, stray `:` bind,
  missing resume arms) report at the invocation; faults owned by a written
  `|` arm report at `cont.location`. `ast.Arg` carries no location, so the
  invocation is the narrowest honest caret for arg-shape faults. Repro'd:
  KORU130 unguarded optional-resume fire → caret on the fire line; missing
  `| timeout` resume arm → caret on the fire line (a missing arm has no
  narrower owner).
- `checkBranchCoverageWithTerminals` non-pilot sites: KORU026 dead-catchall
  (1214, `cont.location` + line-0 fallback), KORU021 bare-return tag (1238,
  `cont.location` + fallback + kind-aware hint), KORU131 pair (1259 `if`-test
  at the parent invocation's `location`, 1313 `when`-guard at `cont.location`
  — different constructs, different owners, matched wording), KORU050
  guarded-only branch (1401, `location` — the absent else owns the call site).
- `validateFlow` KORU042/040 cluster (567, 605–675): `location`/`flow.location`
  — the head invocation IS the fault owner for unknown-tor and unattached
  variant blocks.
- `checkInvokedEventImplemented` KORU047 (802): invocation site — guarded by
  has_impl / impl-head / test-blocks / norun / comptime / glob / abstract
  carve-outs.
- `validatePipelineSteps` non-pilot sites (1643, 1663, 1684, 1695, 1715, 1730,
  1771): `cont.location` throughout — glyph-discipline and resume-arm verdicts
  own the arm.
- `validateProc` KORU050 (1974): `proc.location` — decl owns the
  proc-without-event verdict.
- `validateInlineFlow` KORU040 (2010, 2040): `flow.location` — head invocation.
- `validateLabelJump` KORU041/045/046 (2125–2159) and
  `validateContinuationLabelJumps` KORU041 (2217, 2231):
  `continuation.location`/`cont.location` — the jump site owns it.
- `checkDuplicateBranchHandlers` SHAPE002 (2083, 2090) and
  `checkBranchCoverage` SHAPE002 (167, 174): `cont.location` — the surplus
  sibling owns it.
- `checkForeignDeref`/`validateImmediateImplShape` KORU030 (2306, 2378, 2388,
  2398): `ii.location` — the impl decl owns constructor-shape verdicts.
- `branchKindMismatch` call (1348): `cont.location` — the mis-kinded arm.

### Dead / unreachable sites (recorded, not charged)

- `validateTapContinuations` (867–910, site 903): zero callers. Its
  per-continuation KORU021 at inherited `location` is formally the D2
  defect shape — unreachable, so recorded not fixed.
- `validateEventTap` sites (822, 833) and the wildcard-tap KORU021 (860):
  `.event_tap` items are never produced — `parseEventTap*` removed
  (`parser.zig:4557` note), `~tap` is a `[comptime|transform]` consuming
  `.flow` items (`koru_std/taps.kz`), and the only `EventTap{}` constructors
  in the tree are `tap_collector` unit tests. Site 860 also carries a dead
  guard clause (`cont.branch.len == 0 and !eql(cont.branch, "transition")` —
  the `eql` is vacuously true at len 0).
- `checkBranchCoverage` is `pub` and called by `flow_checker` for non-terminal
  coverage — its SHAPE002 sites are reachable and read clean.

### needs-ruling / unsettled

- **`pair()` / N-absent-fields fires per-field KORU022s** at one caret. The
  claims are unconditionally true (no unknown arg exists to cast doubt), so it
  is not the P1 defect — but "N reports for one arg list" reads as pack noise;
  a single `fields a, b missing` aggregate is the alternative form. Left
  unchanged; wants a wording/arity ruling, not a fix-by-analogy.
- `validateLabelJump` appends `jump_sites` with `.line = 0 // TODO` — latent;
  no current diagnostic reads it.
- KORU040 `unknown tor '{s}'` (675, 1812, 2010, 2040) names the fault, teaches
  no remedy — recorded for the wording-drift family, not charged as a defect.

### Verified vs unverified

- `zig build` clean; `zig build test` green. Repros run against the worktree
  `koruc --deep-check`, with the backend rebuilt manually via
  `zig build --build-file build_backend.zig -Dtarget=x86_64-linux-gnu.2.31`
  — this host is glibc 2.31 and `KORU_BACKEND_TARGET` is unread on this
  branch (fleet brief `backend_target_env_gap`), so koruc's own backend build
  and stage-D `build-exe` produce binaries that cannot exec here. All quoted
  carets come from the 2.31 backend's rendered output.
- `./run_regression.sh` targeted: `Running N tests` matched each run —
  pins 400_225 + 400_226 PASS; controls 400_140/149/150 and
  400_144–148/153/154/156 PASS (12/12 green with the fix).
- Environmental caveat, measured: every checked-out `EXPECT` carries CRLF on
  this clone, so `grep -qF 'substr\r'` never matches the LF `backend.err` —
  every assertion-bearing negative test verdicts `wrong-error` here regardless
  of compiler state. The three control EXPECTs were LF-normalized (their
  git-stored form) to make the run real. Same host-drift family as the
  backend-target gap.
