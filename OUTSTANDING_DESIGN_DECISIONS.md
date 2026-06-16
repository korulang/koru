# Outstanding Design Decisions

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

## D1 — Nested capture: RULED 2026-06-16 — stays; no-shadow field-routing
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

**Codegen work to land it** (refined by a real attempt 2026-06-16):

1. **Give the nested cell-decl a home — fix the RUNNER, not capture's lowering.**
   Capture lowers the cell-decl as flow-level `preamble_code` (`control.kz:401`);
   `itemToNode` rejects `preamble_code` at a nested graft (`transform_pass_runner.zig:86-88`).
   - ❌ **Tried & reverted (don't repeat):** moving the cell-decl into `inline_body`
     — `inline_body` REPLACES the whole body (`emitter_helpers.zig:3815`, ast.zig:593),
     so it deletes every assignment + the after-read. And wrapping the body as
     *children* of a leading `inline_code` continuation regressed the GUARDS
     (`320_027`/`320_042`) with `KORU051` ("branch '' has 2 continuations") +
     `KORU022` ("required branch 'as' not handled"): capture's 2-continuation body
     is only legal via the `@shape_valid` exemption on the flow, and wrapping moves
     it outside that exemption's reach. Lowering must stay untouched.
   - ✅ **Right approach:** make `itemToNode`'s `.flow` case ACCEPT `preamble_code`
     at a nested site — graft it as leading `inline_code` ahead of the body
     children — instead of rejecting it. Confines the change to the nested path;
     top-level capture (and its shape-exempt structure) is untouched.
   - ⚠️ **Open question to ground first:** the nested-graft EMISSION contract —
     does the grafted capture marker-invocation (`new_inv`, carrying
     `@pass_ran`/`@shape_valid`) still matter at a nested site, or is the graft
     just `preamble inline_code + f.body.continuations`? Read the emitter's
     nested-continuation path before cutting.
2. **Make the rewriter multi-cell.** `control.kz:207-257` (`Rewriter.rewrite`)
   takes a single `target`/`cells` and recursively claims **every** `captured` in
   its subtree onto that one cell (line 246-248, no field check, no nested-boundary
   stop). Route each `captured { F }` to the cell declaring `F`; stop descending
   at a nested capture (it owns its own region).
3. **`SHAPE002` duplicate-handler** — downstream of (1)/(2); depth NOT yet read.

**Verified this session:** attempt-1 (step 1 via wrapping) got `320_034` PAST the
preamble crash (frontend compiled, backend generated) before hitting the shape
checker — so the graft point is right; only the *mechanism* was wrong. NOTE: the
live harness is currently FIRE-gated by a pre-existing error-code registry drift
(11 dead declarations in `src/errors.zig`), so verify capture via direct
`./zig-out/bin/koruc <input.kz>` until that's resolved.

Pins `320_034` (implicit/single→named), `320_036` (field-name), `320_038`
(binding-qualified) go green when (1)-(3) land. nbody's `arrayed_capture.kz`
(capture-as-outer-accumulator with `for`/`captured` nested *inside*) already
worked and is untouched; this ruling is about `capture`-directly-under-`capture`.

## D2 — Obligation discharge: where does it belong now if/for are userland templates?
**Tests:** `330_016_scope_nested`, `330_023_if_auto_both_branches` (backend-exec,
KORU030, last green 2026-05-29).
**Grounded root:** two paths in `src/auto_discharge_inserter.zig` encode **opposite**
rules about an explicit `|> _` terminal — the foreach path (`:1192`) discharges *at*
the terminal; the general continuation path (`:957-962`) discharges *only when there
is no* explicit terminal. Regressing commit **`9d35c581`** made if/for userland
`|template|zig` procs, rerouting their branches from the foreach path (discharges)
to the general path (skips) → per-branch discharge silently lost.
**DECISION NEEDED:** Should obligation discharge be a **single terminator-driven pass
that runs uniformly across all continuation kinds** (eliminating the two-policy
split), now that the AST distinction between if/for and ordinary continuations is
gone? Or keep a path distinction and re-thread if/for through the discharging one?

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
