# Outstanding Design Decisions

## WORK ORDER (2026-06-17) — `[aspirational]` annotation gate (make hidden gaps loud)

**Context:** `read-lines` (std/fs + std/io) exposes a per-line *streaming*
surface (`! line`) but its implementation SLURPS the whole file
(`readToEndAlloc`) — RAM-bounded, OOMs on >RAM input. A well-formed API surface
hiding a real problem (Lars is "extremely allergic" to exactly this). Streaming
is the honest fix but was deferred; the gap is now marked, not hidden.

**DONE this session:** both `read-lines` events carry a vertical
`~[ - aspirational <prose> ]` annotation (the existing prose-block annotation
system, `parser.zig:936-1024`; bullets = machine-read flags, prose = discarded
rationale). `read-stdin`/`read-file` are NOT marked — a whole-content read being
RAM-bounded is their honest contract, not a lie. Only the streaming-surface lies
get the flag, so the gap-list stays signal.

**TODO (dedicated/adjacent session) — the enforcement that makes it LOUD:**
1. A compiler-flag gate: refuse to compile when `aspirational`-marked code is
   **reachable** (dead-strip already computes reachability), unless
   `--allow-aspirational` is passed — which prints exactly what it's letting
   through. Polarity = **default-refuse** (CI/release reject; local dev opts in);
   the softer default-allow+`--strict` is too weak per the doctrine.
2. `koruc --list-aspirational` → enumerate every marked site = the canonical,
   greppable gap-list to work against in clean sessions.
3. First customer waiting: the two `read-lines`. Closing the gap = build true
   line-by-line streaming (constant memory, any size), then remove the marks.

Governs: [[no-silent-performance-degradation]] doctrine made structural — gaps
become explicit, enforced, and enumerable instead of hidden behind clean APIs.

---


Surfaced by the 2026-06-15 cluster-by-cluster regression diagnosis (24 read-only
sub-agents, consensus per cluster). These are decisions **Lars must rule on**
before the corresponding regressions can be fixed *right* — fixing without the
ruling just moves the failure around. Go through them one per sitting in a fresh
session; each is grounded in source/commit so the context survives.

**The thread:** three of the four real regressions are the same shape — a recent
*unification refactor* that left one composition case stranded:
`a24afd06` (transforms made position-agnostic), `9d35c581` (if/for became
userland `|template|zig`), `b0f2adb5` (`print` became a `[comptime|transform]`).
Each was correct in intent; each has unpaid follow-through. The decisions below
are mostly "what is the right model now that we unified X?"

---

## D1 — Nested capture: RULED 2026-06-16; step-1 graft LANDED 2026-06-16 (distinct-field nesting green)
**Tests:** `320_034_capture_nested` (implicit), `320_036_capture_nested_qualified`
(field-name routing), `320_038_capture_binding_qualified` (binding-qualified) — all
backend-exec, last green 2026-06-02.
**Grounded root:** `capture` emits a flow-level `preamble_code` (the `var <cell> = …`
decl) at `koru_std/control.kz:401`. At a nested site the runner grafts via
`itemToNode` (`src/transform_pass_runner.zig:83`), which **hard-rejects** a flow
with `preamble_code != null` (`:86-88`, `TransformPreambleAtNestedSite`) — a
continuation has no preamble slot. Regressing commit **`a24afd06`** deleted
capture's old `is_top` nested-decline guard AND added the trap. Multi-layer:
layer 1 = this preamble crash; layer 2 = shape checker rejects the spliced capture
continuations as `SHAPE002` duplicate handlers; likely layer 3 in emission. NOT a
one-line fix.
**RULED (Lars, 2026-06-16): nested capture STAYS. It is a codegen fix, not a
design fork — the supposed routing ambiguity does not exist.** Model:

- **Field-name routing, no shadowing.** `captured { F: v }` writes to the cell
  whose struct declares field `F`. Cells nested inside each other may **not**
  share field names. No-shadowing is the convention (Lars prefers it
  language-wide), but **rejection of shadowing is left to the Zig backend** — we
  do NOT build a Koru-level shadow-checker (ruled 2026-06-16; `202c` stays a
  deferred red). The job is only to make *correct* (non-shadowing) nested capture
  compile; with no shadowing, the target cell for every `captured { F }` is
  unique by construction. `captured { outer: … }` written inside an inner region
  reaches past the inner cell to `outer` because only `outer` declares that field.
- **Sub-rule:** nested captures require **named** `captured { F: v }` fields;
  bare positional `captured { v }` is single-cell-only (ambiguous across cells).

**Codegen work to land it** (step 1 LANDED 2026-06-16; findings below):

1. ✅ **DONE — give the nested cell-decl a home in the RUNNER.** `itemToNode`'s
   `.flow` case now ACCEPTS `preamble_code` at a nested site: it grafts the
   preamble as a void `inline_code` **node** carrying `f.body.continuations` as
   that node's children (`transform_pass_runner.zig:86`). This reproduces the
   flow-level emission contract EXACTLY — at flow level the emitter writes the
   preamble verbatim, then emits the body continuations directly, and `return`s
   *skipping the marker invocation* (`emitter_helpers.zig:3801`). At a nested
   site, `inline_code` is a **void step** (`emitter_helpers.zig:7379`), and a
   void step emits its children *directly as a void chain* (`:7492`), not as
   result-switch arms — same code path (`emitContinuationBody`). **Open question
   RESOLVED:** the marker invocation does NOT matter at a nested site; the graft
   is just `preamble inline_code + f.body.continuations`, dropping the marker
   exactly as the flow-level path drops it.
   - ❌ **Tried & reverted earlier (don't repeat):** moving the cell-decl into
     `inline_body` (REPLACES the whole body) or wrapping the body as *children* of
     a leading `inline_code` continuation (regressed guards `320_027`/`320_042`
     with `KORU051`/`KORU022` — moves capture's 2-cont body outside the
     `@shape_valid` exemption). The landed fix touches NEITHER lowering nor the
     shape exemption: it grafts at the runner, the preamble becomes the *node*
     (not a wrapping cont), and the body rides as that node's children.
2. **Step 2 (multi-cell rewriter) turned out UNNECESSARY for distinct-field
   nesting.** D1 predicted the single-cell rewriter would mis-claim. It does NOT,
   because `Rewriter.rewrite` only walks the `! as` body subtree
   (`control.kz:257`) — the `| captured` terminal body is assembled separately
   (`:276-301`) WITHOUT being rewritten. So a `captured` sitting in an inner
   capture's terminal survives un-claimed; depth-first nesting then lets the
   ENCLOSING capture claim it. Routing is **boundary-based**, not field-name
   dispatch — and it produces correct cells whenever fields are distinct.
   Verified green: `320_034` (→42), `320_036` (→`outer=10, inner=10`),
   `670_015`/`670_010` (→`n=1`). Mis-routing (wrong field) is caught by the Zig
   backend (no such field) — the "rejection deferred to Zig" model, satisfied.
3. **RESOLVED 2026-06-17 — capture nested under a NON-capture branch** (`670_011`
   scalar, `670_012` obligation, `670_013` effect, `670_014` for_each, `320_098`)
   **all GREEN.** Board 752→757 (89.4%), zero regressions; guards `320_027`/`320_042`
   and the previously-green capture row (`320_034`/`036`, `670_010`/`015`) held.

   **RULED (Lars, 2026-06-17): the flag, not a new node kind — coarse exemption,
   trust the Zig backend for now.** "If we can improve our templating system and
   flag them, that is going to be so much more powerful… allowing the Zig backend
   to catch real mistakes is completely fine. It's not the way it's going to be
   forever, but for now I think it's great."

   **Mechanism that landed:** a new `is_transformed_subtree: bool` on
   `ast.Continuation` (the nested mirror of the flow-level `is_transformed`). The
   preamble graft (`transform_pass_runner.itemToNode`, `NodeConv.mark_transformed`)
   stamps it on the holding continuation when it splices the `inline_code` preamble
   + `''` void-chain; the flag is threaded through
   `replaceInvocationNodeAndContinuations*` → `cloneContinuationWithNodeAndContinuations`,
   and PRESERVED across every other clone path (general `cloneContinuation`, the
   `With*` variants, `ast_transform.cloneContinuations`) so it survives subsequent
   passes. Both checkers short-circuit the structural recursion when they descend
   into a flagged continuation: `flow_checker.checkDuplicateBranchHandlers` (SHAPE002)
   + `validateContinuationWhenClauses` (KORU050/051), and
   `shape_checker.checkDuplicateBranchHandlers`. `shape_checker.checkBranchCoverage`
   (:111) was NOT touched — it never fired once the earlier sites were exempted
   (don't add speculative skips). KORU022/layer-3 emission never surfaced; the graft
   already models the void chain correctly, so compilation + runtime are clean.

   **Below: the original GROUNDING that mapped the cascade (kept for the record).**

   **GROUNDED 2026-06-17 (mapped the full cascade, then reverted the probes —
   too chunky to finish without risking the guards `320_027`/`320_042`).** The
   D1 graft embeds capture's lowered **void-chain continuations** (`.branch = ""`,
   the `! as`/`captured` steps) into the enclosing flow. At flow level these are
   exempted by `@shape_valid` on the capture flow's invocation; at a nested graft
   that exemption is GONE (the graft drops the marker invocation, by design — see
   step 1). So every checker that special-cases capture's `''` chains now trips,
   in a cascade (confirmed by probing `670_011` `capture-under-scalar`):
     - **SHAPE002 "duplicate handler for branch ''"** — fires from THREE sites:
       `shape_checker.zig:111` (`checkBranchCoverage`), `shape_checker.zig:1285`
       (`checkDuplicateBranchHandlers`), and the real first-firing one
       `flow_checker.zig:729` (`checkDuplicateBranchHandlers`). `''` is the
       void-chain/sequential marker, never a named-branch collision.
     - **KORU051 "branch '' has 2 continuations without 'when' (ambiguous)"** —
       `flow_checker.zig` `validateWhenClauseExhaustiveness` — surfaces next, once
       SHAPE002 is cleared. This is the SAME rule that regressed the guards in the
       D1 step-1 wrapping attempt.
     - Likely more flow-checker rules (KORU022 branch coverage) + a **layer-3
       EMISSION** issue beneath (not yet reached).
   **Why piecemeal `''`-exemption is the WRONG fix:** patching each checker to
   skip `''` is whack-a-mole, risks wrongly exempting legitimate checks, and
   doesn't address emission. **The principled fix:** propagate the
   "already-validated, don't re-check" status (the `@shape_valid` exemption that
   the capture FLOW carried) to the grafted subtree, and honor it UNIFORMLY across
   shape_checker + flow_checker recursion (+ emission). Open design question: what
   carries the exemption at a nested site — re-stamp `@shape_valid` on the holding
   continuation and teach every checker's recursion to short-circuit on it, or a
   dedicated "transformed-subtree" boundary marker? Note the flow-level checks key
   the exemption on `flow.inv().annotations` / `is_transformed`
   (`flow_checker.zig:89`), which a nested continuation has no equivalent of yet.
   **Next-session entry point:** decide the exemption-propagation mechanism FIRST
   (design), then apply it across the cascade, guarding `320_027`/`320_042` green
   throughout; verify via direct `./zig-out/bin/koruc` on `670_011` (+ the rest of
   the 670 capture-under-X row) — harness FINAL verdict still FIRE-gated by the
   `errors.zig` registry drift.

**320_038 binding-qualified shadowing — RESOLVED 2026-06-16: DELETED as stale
intent.** It tested binding-qualified routing (`captured { inner.count: … }`) to
disambiguate SHADOWED cell fields (both cells declared `count`) — which
contradicts D1's no-shadow ruling, and binding-qualified routing was never ruled
in. The surviving intent (distinct-field nesting) is already green in 320_036;
binding-qualified `captured { x.y: }` appeared in zero other tests. Per greenfield
doctrine the test followed the dead intent. Deleted in `1ccb01dc`.

**Verified 2026-06-16 (this session):** built `koruc`, compiled+ran each target
via direct `./zig-out/bin/koruc` (harness FINAL verdict is FIRE-gated by the
pre-existing 11-dead-code `errors.zig` drift, but per-test PASS/FAIL prints).
Full cached suite: **748/848 (was 745)**, +3 net = `320_034`/`320_036`/`670_015`
red→green; guards `320_027`/`320_042`/const `320_043`/`320_044` stay green; no
non-capture test newly broken (the fix only touches the `preamble_code` arm of
`itemToNode`, which previously always errored → green→red is impossible).

nbody's `arrayed_capture.kz` (capture-as-outer-accumulator with `for`/`captured`
nested *inside*) already worked and is untouched; this work is about
`capture`-directly-under-another-construct.

## D2 — Obligation discharge for multi-terminal flows: FIXED 2026-06-16
**Tests:** `330_023_if_auto_both_branches`, `336_003_string_instance_drop_discard_branch`
→ GREEN. `330_016_scope_nested` discharge-layer fixed (now blocked on a SEPARATE
nested-for emitter bug, below).
**Doc's original framing was WRONG (corrected by grounding the real failure).** The
"two opposite policies on explicit `|> _`" story didn't hold: single-terminal
discharge already worked (330_015 for-loop, 330_022 manual-if green). The actual
root cause: in `.full` mode the FIRST disposal called `markFlowProcessed`, stamping
`@auto_discharge_ran` on the whole flow; the `.full` re-run then SKIPPED the entire
flow (`auto_discharge_inserter.zig:582`). So a flow needing disposal at TWO terminals
— `if`'s `then` AND `else`, or a nested loop's inner AND outer — only ever got the
FIRST; the second was never revisited in `.full` (only later in `scope_exit_only`
mode, which doesn't dispose). Proven via a `mode=full` vs `mode=scope_exit_only`
trace at the dispose decision.
**FIX (landed):** removed the `@auto_discharge_ran` per-flow short-circuit and the
whole dead mechanism (the `:582` skip check, 4 `markFlowProcessed` call sites, the
function). The fixpoint now finds EVERY terminal; the inserted `close` satisfies each
terminal so re-walks are idempotent and it CONVERGES (`insertDisposals` returns
`error.ValidationFailed`, never spurious `transformed=true`, when no disposal exists
— so no infinite loop). Full no-cache suite: **750/847, ZERO regressions**, +2 real
greens (330_023, 336_003). `markFlowProcessed` was a pure optimization that happened
to break multi-terminal flows.
**Orthogonal / deferred (NOT needed for these tests):**
- **`@scope` declaration (was "(B)").** Ruled to do, but it's a PRECISION cleanup of
  the `kind == .effect` heuristic (which over-broadly treats `! as` as a loop), not
  what fixed discharge. Separate follow-up; spelling chosen `[@scope]`, needs parser
  support for event-decl branch annotations (the `ast.Branch.annotations` field
  exists; the parser never fills it).
- **Nested-for `result_N` var shadowing (emitter) — FIXED 2026-06-16.** `330_016`
  green. Root cause: the effect-splice result prefix (`emitter_helpers.zig:3477`)
  REPLACED the namespace with `result_e{d}_` from the local effect index, so a
  nested `! each` (also idx 0) collided with its parent → both emitted
  `result_e0_0` at the same Zig function scope → "shadows local constant". Fix:
  NEST the prefix (append `e{d}_` to the enclosing prefix) so inner gets
  `result_e0_e0_`. Single-level emission is byte-identical (`result_` →
  `result_e0_`); only nested splices change. Full no-cache: 751/847, zero
  regressions, +1 green (330_016).
- **`330_012` / `330_071`** explicit-with-multiple & aspire-chain — not yet diagnosed;
  likely separate.

## D3 — Comptime-internal printing (and comptime events that need AST context)
**Tests:** `310_050_build_flag_check`, `310_051_build_variants` (backend-compile);
`310_049_invocation_meta` ultimately needs the same. Last green 2026-06-11.
**Grounded root:** `b0f2adb5` made `std/io:print` a `[keyword|comptime|transform]`
event whose Input requires `expr, invocation, item, program, allocator`
(`koru_std/io.kz:21-27`). Called from *inside* a `[comptime]` flow, the
comptime-injection codepath emits the handler call without `.invocation`/`.item`
(none are in scope) → Zig "missing struct field".
**DECISION NEEDED:** How does a comptime event that needs AST-context pointers get
**called from inside another comptime flow**, where no `Item`/`Invocation` is in
scope? `b0f2adb5` names the candidate answer: a **`std/compiler:print` stage-facet**
— i.e. is comptime-internal printing a SEPARATE facet from runtime `print`?

## D4 — Governing syntax/policy for EXTERNAL repos compiled via koru.json
**Tests:** `350_005_static_router_nested` (frontend, last green 2026-06-07) — and
the orisha router cluster generally.
**Grounded root:** `350_005` does `~import orisha`; `koru.json` maps `orisha` to the
external repo `../../../orisha/lib`. Koru commit **`0ee0fc25`** added
`looksLikeBareKoruModuleConstruct()` (`src/parser.zig:1033-1045`) rejecting bare
`import`/`event`/`proc` in host-embedded files (PARSE003). `orisha/lib/routing.kz:13`
has a bare `import std/testing` (no `~`), so loading orisha now trips the new rule.
**DECISION NEEDED:** How should koru govern language-level syntax/policy for external
repos it compiles via path-mappings, which it **cannot edit**? Options: (a) a
`koruc fix`/codemod that operates on dep source trees; (b) a vendoring step; (c)
version/pin the dep's expected language level so a flip doesn't silently break it.
The one-line `~import` fix in routing.kz is a symptom patch, not the decision.

## D5 — Metatype ownership: declaring event/branch vs referencing catch-all site
**Tests:** `210_017_catchall_end_to_end` (backend-exec); `210_029_transform_requires_comptime`
(must-fail-passed). Underlying bugs are OLD (`a9604495`), not from the last-green
window. (Lower confidence: 2 of 3 diagnosers failed "prompt too long".)
**Grounded root (210_017):** the catch-all handler emits a `taps.Transition{…}`
reference (`emitter_helpers.zig:6417`), but `taps` emission is gated on
`has_referenced_events_or_branches` (`visitor_emitter.zig:712`); `scanForMetatypes`'
catch-all arm (`:578-583`) sets `result.transition = true` but, unlike the
non-catchall arm, registers no events/branches → emitter and handler disagree.
**DECISION NEEDED:** Is metatype info (Transition/Profile/Audit) carried by the
**event/branch that declares it**, or by the **catch-all site that references it**?
And: does `[transform]` intent live in an **annotation** or is it **inferred from
parameter types**? Both halves are currently inconsistent.

## D6 — Where (and by what rule) is an invalid module qualifier rejected?
**Tests:** `510_011_invalid_module_qualifier` (no-error-pin). This was a **false-green**:
the test was written expecting a rejection that was never implemented.
**Grounded root:** the frontend does NOT reject short-form `io:print.ln`
(`input.kz:14`). The only nearby guard, `rejectDotNamespace` (`src/parser.zig:1343`),
fires only when the qualifier contains a `.` — `io` has no dot, so it sails through;
backend then crashes with "Unknown event referenced".
**DECISION NEEDED:** Should the FRONTEND reject any qualifier that doesn't resolve to
an imported module (module-qualifier resolution becomes a parse/frontend check, as
the test assumes) — or is qualifier resolution legitimately a backend/registry
concern (and the test is wrong about where the error belongs)?

## D7 — Row identity: the ruling EXISTS (O10). It is a handle, not a key.
**Rewritten 2026-07-31.** The previous framing asked "how is a key marked at
`new`?" and treated identity as an open design question. It is not. It was ruled
in `690_STORE/DESIGN.md` O10, and it is a MEMORY CONTRACT, not a user surface:

> (iii) THE MEMORY CONTRACT is ruled, the mechanism is the planner's: dense
> iteration, O(1) insert/take, **handles stable across other rows' removal**
> (sparse-set vs slot-freelist = planner per workload; **swap-remove legal
> because positional index is not identity**).
> (iv) **HANDLE-SAFETY FLOOR: generational check per access (one compare)** as
> the safe default; phantom-proven elision where the checker establishes
> no-stale — THESIS, same floor-then-prove-away arc as the concurrency lock and
> escape-driven stack alloc.

**So a store needs NO key for identity.** It needs its handle to BE a handle —
slot plus generation — instead of the raw `i64` position it hands out today.
`690_092` corrupts silently because the ruled design was never built: `| row a`
yields a bare position, and `[tree]`'s synthesized `parent` is documented as an
"i64 row handle, -1 = root", which is a position wearing the word handle.

**This also disposes of `! moved`.** An effect branch firing on relocation exists
to let an outsider fix up stored positions. Under O10 no outsider holds a
position, so there is nothing to fix and nothing to notify. The arm was killed
2026-07-28; that is the reason, and it was recorded as a conclusion without it.

### What the CORE surface needs: nothing
`insert`, `sweep`, `query`, `preorder`, `take`, `stored`, `watch` and the
lifecycle arms are all "you have the row right now". Measured: **no test holds a
row handle across a remove** — all 18 `| row X` + removal co-occurrences are
bind-then-consume. Stored positions are exactly 5 tests (`695_001/002` tree
parent, `690_048` self-FK `next`, `690_075/076` `todos[ui.sel]`), **none of which
removes a row** — the sole reason `690_092` never surfaced.

### FEASIBILITY (assessed 2026-07-31) — buildable, one ruling short
- **No new type spelling is needed.** Pack slot+generation into the existing
  `i64`. `next: i64`, `ui.sel`, and `[tree]`'s `parent` all keep working
  unchanged; only the meaning of the bits changes. This matters because
  DESIGN.md's own HANDLE GAPS note says a plain handle has **no type spelling**
  for leaving its chain — packing sidesteps that rather than waiting on it.
- **The lowering site is centralized**: `indexedFieldRefs` (`store.kz:4534`) is
  the single function every `<store>[expr].<field>` passes through. ⚠️ It is a
  TEXTUAL rewrite, so it carries the standing store-is-text hazard.
- **The swap already has both ends live** — `__koru_r` and `__koru_last`,
  `store.kz:2717-2722` — and the write path already calls out mid-atomic-step
  (`store.kz:2075`). A post-swap emission point was spiked and SHOWN to fire with
  both ends (`from=2 to=0`).

### ⛔ THE ONE RULING THAT BLOCKS THE BUILD
**What does a stale handle access DO?** O10 rules that the check happens; it does
not say what failing it means.
- **(a) Trap.** Matches "safety FLOOR" and the loud-failure doctrine, needs NO
  surface change, and every existing use site keeps compiling. Phantom-proven
  elision then removes the check where the checker establishes no-stale.
- **(b) A branch the program handles.** Precedent exists — `take` already offers
  `| item` / `| empty` (690_075). But it changes EVERY bracket use site, which is
  a large surface change for a case the corpus says is rare.

### Still open, and genuinely separate from identity
- **Addressing by value** — `pool[id: 7].hp`, one of O2's four heads. THIS is
  where the `key:` spelling lives, and it is a query convenience, not identity.
  It carries its own unsolved problem, flagged in DESIGN.md as **KEY COLLISION**:
  map precedent (silent overwrite) would invalidate the prior row's handle
  through ordinary control flow — manufactured staleness — so `key`'s SQL
  connotation demands reject-or-branch.
- **ITERATION CONTRACT** — DESIGN.md flags that DELETE WHERE (O2) and
  swap-remove (O10.iii) were never checked against each other; that is the
  classic iterate-and-remove bug, needing deferred compaction or
  removes-apply-after-scan.

**Unblocks:** `690_092` goes green; `downloads`' double sweep; and the resource
bridge's "what names a handle across turns", which is this question one lifetime
domain up.

## D8 — The sweep row ORDINAL has no spelling
**Pin:** `690_069` (red since 2026-07-28; was green before).
**Grounded root:** the 0-based ordinal used to be a reserved bare `row` inside
the projection block. 690_086's ruleset (ruled 2026-07-28) binds the row and
routes every reference through `<row>.<field>` — and an ordinal is **not a
field**; it is a property of the visit, not of the row. The seven rules do not
mention it, and neither DESIGN.md nor the membrane rules it elsewhere. The pin
holds the retired projection form on purpose, so the requirement does not leave
the corpus along with the syntax that carried it.
**Why it is real:** it is the layout cursor a retained renderer needs —
`! draw |> sweep(store) ! sweep <row> |> write-at(y: <ordinal>, …)`. What a row's
fields say is independent of WHERE it sits on screen, and only the sweep knows
the second thing.
**No sibling answers it:** `for` binds `! each i` with no counter, so nothing in
the language currently hands a loop its index.
**DECISION NEEDED:** the spelling. NOTE the interaction with D7 — an ordinal is a
POSITION, and under swap-remove position is not identity, so whatever this
becomes should not read like a handle a program can store.

---

## WORK ORDER — phantom state cross-module resolution

**Context.** A phantom state is only meaningful relative to its *declaring
module*. Today `phantom_semantic_checker.zig` canonicalizes a **bare** state
(`<list>`) against the **defining module of the field** that carries it
(`event_decl.module`). That works inside the declaring module — `std/list`'s own
`push { xs: *List_i64<list> }` canonicalizes to `std/list:list`. But it breaks
the moment a state is referenced **outside** its declaring module: a user
module's `rle { nxt: *List_i64<list> }` canonicalizes to `<user>:list`, which
will never unify with the `std/list:list!` that `new-i64` issued. This is GAP B
error 1 in the day10 handoff (`expected 'day10_wip_list_rle:list' but got
'std.list:list!'`). The same mechanism blocks any user event that takes a
std-collection handle param.

**Why bare-is-not-enough (the scalar case).** Phantom states are not exclusive
to handle types — scalars carry them too (`n: i64<epoch>`, `c: 22.5<celsius>`).
A builtin scalar has no home module, so the state's module cannot be implied
from the type. The state must name its own module. Applying the *same* rule to
handle types (one resolution path, not two) is more consistent than
special-casing handles.

**DECISION (ratified 2026-06-19, design by GLM + Lars).** Phantom states carry
their own module, independent of the field's type, mirroring how event/type
paths already resolve (`std/list:push`). The rule:

- **Bare** `<list>` / `<list!>` / `<!list>` — legal only **inside** the
  declaring module; resolves to *this* module. (Equivalent to a self-qualified
  reference.)
- **Qualified** `<module/state>` — legal everywhere; **required** outside the
  declaring module. A user module borrowing `std/list`'s list-state writes
  `<std/list:list>`, `<std/list:list!>` (issue), `<std/list:!list>` (consume).
- **`!`-modifiers stay on the state token**, never on the qualifier:
  `std/list:!list` (consume), `std/list:list!` (issue), `std/list:list`
  (borrow). The qualifier is a pure scope prefix; the `!` semantics are a
  property of the state. (Rejected alternative `<!std/list:list>` — makes the
  `!` a property of the whole cross-module reference, which is a category
  error, and breaks uniform left-to-right parsing.)
- **Union:** `<member|member>`, each member a fully-qualified-or-bare state per
  the above, e.g. `<std/list:!list|app/coins:coins>`. Per-member qualifier;
  no factored shared qualifier (members may come from different modules).
- **Canonical separator: slash** (`std/list`), matching import paths — NOT dot.
  The current canonical form emits dot (`std.list:list!`); that is a bug.
  `module_map` is today keyed on the dot `local_name` (`std.list`) with the
  slash import path as value; it must move to slash keys (or normalize at
  lookup) so a written `<std/list:list>` resolves.

**Verification stance (lexical, like events).** The checker resolves the
qualifier through `module_map` and confirms the module is imported/declared —
the same check it runs for event qualifiers. It does **not** verify "this state
belongs to this type": a state's home is lexical, declared by usage, same as
events. This **decouples** this design from the separate type-qualification gap
(handle types like the list collection type carrying no `module_path`, so the
emitter writes a bare unqualified type that's undeclared in a user module).
That is its own concern ("issue 4" in the day10 brief); do not conflate.

**Scope explicitly OUT of this design:**
- Type `module_path` population for handle types (issue 4 / GAP B type half) —
  separate. The state-qualification rule here does not depend on it.
- Obligation threading through label-fold bodies (GAP B error 2: a `<!list>`
  consume-param losing its tracked state across the fold) — narrower bug in
  checker scoping, adjacent to the `29595b5a` seed-credit work; separate fix.
- Changing the `~capture` transform to rewrite `=> captured {...}` in terminal
  position (day10 symptom 2) — separate.

**Landing plan (breaking tests first, no silent partial).**
1. Add failing regression tests (honest RED) covering the rule: a user module
   that references `std/list:list` cross-module and hits KORU030 today; a
   scalar-phantom cross-module reference (`app/time:i64<app/coins:epoch>`);
   the bare-outside-declaring-module rejection. Mark expected post-fix behavior.
2. Fix canonical form to slash + `module_map` slash keying. Flip the
   unification tests green.
3. Enforce bare-state-only-inside-declaring-module (reject bare outside).
4. Emit clearer KORU030 messages using the user-facing qualified spelling,
   never the internal canonical form.

**Status:** DESIGN RATIFIED, NOT YET IMPLEMENTED. The two unrelated fixes
landed this session (commit `3e2cdaa8`: capture-fold body emission under
continuation branches; positional-arg parsing with pre-dot operators) are safe
forward progress independent of this design.

---

## Non-decision follow-ups (fixes, not design — but don't lose them)
- **`330_060`, `521`** — NOT regressions. Pre-existing MUST_FAIL *gaps* the harness
  only started detecting (commit `7ac02be1`). Need the missing validations BUILT:
  `521` = second obligation field (`f.file2 <opened!>`) untracked at a void terminator;
  `330_060` = required non-obligation state annotation not enforced at the call site.
- **`2104_05`** — KORU030 fires correctly but reports the synthesized internal name
  `_auto_0` at `auto_discharge:11:0`; the test wants the user-facing `Connection` /
  `input.kz`. Diagnostic-provenance fix.
- **`330_012`** — broken TEST INPUT: a layout fold (`0add561a`) moved `| err _ |> …`
  from 8-space (a branch of `write`, which declares `| err`) to 4-space (a sibling of
  `| locked`, which doesn't) → KORU021. Fix the indentation in the test.
- **`day17` (`810_171`)** — left as the half-solved intake stub this session (prints
  "5" not "4"); not a regression, just incomplete.

## Ignore-for-now pile (Lars's call, 2026-06-15)
JS/cross-target (`140_014/015`, `630_001`), taps (`310_013`, `504`), interpreter
(`410_010`, `430_020/035/042`). `430_005` held pending the interpreter-boundary call.
