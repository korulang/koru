---
challenge: obligation-control-flow
kind: frame
status: standing
yields: the obligation system holds across every place control flow bends, or names the bend it cannot cross
family: thesis
---

*Walker context — the recurrence that earned this frame. "Control flow into the
type system" is the thesis. `330_PHANTOM_TYPES` and `335_OBLIGATION_STRESS` are
where that claim is tested, and together they carry **34 reds** — the largest red
mass on the board (22 + 12 of 124 + 22 tests).*

*They are not scattered. Sorted by what the program does rather than by number,
they cluster around the places control flow **bends**: a loop's back edge, a
borrow, an error branch, a tap, a continuation, a mid-chain return with no name.
Straight-line obligations work. Bent ones are where the system runs out.*

---

## ⚖️ RULED BY LARS 2026-07-31 — THIS IS A "GO SLOW IF NOT 100% SURE" PASTURE

*"`012` is OBVIOUSLY the most important thing here — phantom types MUST run
green at some point. This feels like a 'go slow if not 100% sure' pasture."*

That is a instruction about **method**, and it inverts the usual scoring:

- **A located cause with no fix is a SUCCESS.** Write it, with the evidence, and
  move on. You are not behind.
- **A green test you cannot fully explain is a FAILURE**, even though the board
  went up. If you cannot say *why* it went green, you have not finished — say so.
- **Diagnose all 24 BEFORE fixing any.** The cluster map is the deliverable. A
  fix landed early distorts the evidence for every test still undiagnosed.
- **When unsure, STOP and write.** Do not try it and see. This subsystem is where
  a plausible-looking patch does damage that stays hidden — the whole thesis
  rests on obligations being airtight, and a wrong fix here is worse than a red
  test because it converts a loud failure into a silent one.

⛔ Explicitly do NOT optimise for count. Twenty-four diagnosed and four fixed
beats twelve greened and twelve disturbed.

## The brief (sealed — you are the contestant)

Establish the **cluster map**: which of the 24 share a mechanism, and what that
mechanism is. Close **only** the clusters whose cause you can prove. For the
rest, produce the diagnosis.

One cluster closed with its mechanism named beats six tests greened by six
unrelated patches.

### ⚠️ The list, refreshed 2026-07-31 — the older list below is stale

`010` closed five of the six state-variable tests, so the advice further down to
"start with the state-variable cluster" no longer applies — only `525` remains.
Current, from board `ed9c75a0`:

**Loops and back edges** — `330_084`, `330_085`, `330_086`
**Borrow** — `330_091`, `335_046`
**Error branches leak what the happy path frees** — `335_006`, `335_007`,
`335_022`, `335_023`
**Taps** — `330_030`, `330_031`
**Wildcard metatypes** — `330_009`, `330_010`
**Singles** — `330_019`, `330_050`, `330_060`, `330_076`, `330_078`, `525`,
`910_phantom_state_valid`, `335_044`
**Design pins, spelling-blocked, DO NOT FIX** — `335_042`, `335_043` (the IO
allocation-label question is already written and belongs to Lars)
**Cause already in its own header** — `330_120` (see below)

## Ground yourself FIRST — three of these are already diagnosed

**`330_120_unbound_bare_return_obligation_auto_discharges`** is **Tier 1 in
`baton_store_red_pin_queue`, with the cause written into its own header.**
`start(): j |> abandon(j)` hands back an obligation nobody named.
`auto_discharge_inserter.zig` records an unnamed return as
`__unbound_return.<event>` and force-marks it not-auto-dischargeable, because an
unnamed value has no referenceable expression. The machinery to mint a name lives
next door: `cloneContinuationWithReturnBinding` synthesizes `_auto_N` for `: _`
discards. Control: write `: b` and the identical program compiles. **A name is
the only difference, and a name is not information the compiler was missing.**

That one needs no ruling. It is the warm-up and it unblocks the
`| full |> curl:cancel()` spelling in `downloads`.

**`335_047` / `335_048`** carry a suspected site with line numbers — see
`challenges/010_the_refusal_audit.md`, which owns the *refusal* question for
them. This frame owns the *mechanism*.

**PASS ORDERING** is named in the red-pin baton as the one Lars calls essential:
`desugarBindingPuns` runs inside `desugar-chains`, left of every transform stage
in `~elaborate` (`compiler.kz:1199`), so a branch a transform synthesizes later
can never offer its payload to the thread. The recorded fix is a **second run
after the transform stages, not a move** — the fill is already idempotent
(`isOpenThreadSlot` skips filled slots). ⚠️ And it was **measured on 2026-07-28
that the desugar trio already runs twice per compile**, which refutes "re-entry
is unsafe." Do not re-establish that; read `baton_argument_resolution_by_type`.

## The clusters, as they sort

**State variables — a self-contained feature, 6 tests, mostly one file:**
```
522_state_variable_wildcard          523_state_variable_constrained_accepts
524_state_variable_constraint_violation (wrong-error)
525_state_variable_chaining          330_050_union_accepts_either_state
330_060_reject_state_mismatch_on_input (frontend)   910_phantom_state_valid
```
This is the highest-density cluster on the board and it looks like one feature
half-landed. Start here if you want the cause located fast.

**Loops and back edges — the thesis at its sharpest:**
```
330_084_nested_loop_carries_outer_obligation
330_085_obligation_held_across_back_edge
330_086_inline_nested_fold_outer_obligation
```
Note their green neighbours `330_075_back_edge_drops_obligation`,
`335_004_loop_body_discharges_outer`, `335_005_nested_loop_inner_discharges_outer`
all pass. The *rejections* work; the *carries* do not. That asymmetry is the
diagnosis waiting to be read.

**Borrow:**
```
330_091_auto_discharge_disable_leaks_through_borrow
335_046_continuation_after_borrow_auto_discharges
```

**Error branches leak what the happy path frees:**
```
335_006_err_branch_leaks_opened_resource
335_007_chain_second_err_leaks_first_resource
335_022_disconnect_before_commit    335_023_disconnect_before_rollback
```

**Taps and wildcard metatypes — likely unrelated to the rest, check before merging:**
```
330_009_universal_wildcard_metatype   330_010_module_wildcard_metatype
330_030_taps_with_auto_discharge      330_031_tap_binding_substitution
```

**Multiple resources:**
```
520_multiple_resources_cleanup
521_multiple_resources_partial_cleanup   (config-error — pins no diagnostic)
```

**Shared with `010_the_refusal_audit` — coordinate, do not duplicate:**
`330_118`, `524`, `335_020`, `335_021`, `335_042`, `335_043`, `335_047`,
`335_048`. 010 asks *should it refuse*. This frame asks *why doesn't it*. If both
are running, the mechanism belongs here and the verdict belongs there.

## The pre-garden — read the pins before trusting them

`73` test files in the corpus carry `RED PIN` / `PIN (` header language, and
several of these 34 are among them. A red pin is a **prediction**, and a
prediction can go stale:

- **Does the pin still describe what happens?** `320_048` was an intentional red
  pin that predicted its own fix and went green on it. Others may have drifted —
  the program still fails, but for a different reason than the header claims.
- **Is any of these a `MUST_ERROR` laundering a red pin?** The harness wall at
  `regression_lib.sh:608` blocks the unpinned case, and `521` is currently caught
  by it. Check whether `521` is a real design pin or an abandoned test.
- **Do the test comments state red/green state?** `CLAUDE.md` forbids it: write
  what the test *pins*, not what it does today. Fix any you find — that is
  ordinary gardening and it is in scope.

## What "done" looks like

- A cluster map with mechanisms, and for each cluster: cause located, or the
  specific experiment that would locate it.
- `330_120` closed (cause is in its header; no ruling needed).
- The state-variable cluster either closed or reduced to one named gap.
- Any pass-ordering work done as a **second run**, with the measurement that
  justifies it re-run rather than assumed.
- Spelling questions written, not answered. Tier 2 of the red-pin baton
  (`690_092`, `690_069`, `690_018`) is blocked on Lars for exactly this reason —
  respect the same boundary here.

## Failure modes

- **Merging clusters on silhouette.** `690_090` and `690_094` looked identical and
  were **two mechanisms**; the hypothesis that they were one was tested and
  refuted on 2026-07-28. Same discipline here: resemblance is not evidence.
- **Re-establishing refuted beliefs.** "Re-entry into the desugar trio is unsafe"
  is refuted. Read the batons before designing.
- **Greening a `MUST_ERROR` by loosening its pin.**
- **Running the full board.** Affected tests plus controls. Filtered runs write no
  snapshot, so they cannot clobber the published board.
