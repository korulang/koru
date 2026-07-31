---
challenge: refusal-audit
kind: frame
status: standing
yields: every test that pins a refusal either refuses, or says out loud and in public that it does not
family: correctness
---

*Walker context — the recurrence that earned this frame. Koru's pitch is that
the compiler refuses what other languages permit. The board says that is true
1154 times. It also says that **29 tests currently pin a refusal that does not
happen, or happens for the wrong reason**. Thirteen `must-error-passed` (the
program compiles and it must not), eight `wrong-error` (it is refused, but the
diagnostic names something else), seven `expected-error-missing`, one
`no-error-pin`. Two of the thirteen are in `910_LANGUAGE_SHOOTOUT` — the
category whose entire job is to show a visitor what Koru catches.*

*Every other red on the board is a feature that is **incomplete**. This set is
different in kind: it is the compiler saying green where the language promises
red. A missing feature disappoints. A missing refusal misleads.*

---

## The brief (sealed — you are the contestant)

Take the 29. For each one, establish **which of four things is true**, with
evidence, and then act differently for each:

1. **The compiler is wrong.** The refusal is specified, wanted, and absent. → Fix
   the compiler. The test goes green by the code changing.
2. **The test is wrong.** It pins a refusal the language never promised. → The
   test is deleted or converted to a positive, and the reason is written down.
3. **The refusal is real but the diagnostic is wrong.** → Fix the diagnostic;
   the pin was doing its job.
4. **The refusal needs a spelling or a ruling that does not exist.** → Do not
   invent it. Write the question, with the evidence, and stop at that test.

You may not close a test by moving its pin. That is the one move this frame
exists to prevent.

## Ground yourself FIRST — the corpus is healthier than it looks

Before diagnosing anything, understand what the harness already guarantees, or
you will spend a day rediscovering a wall that has been standing for weeks.

`scripts/regression_lib.sh:608` already **fails any `MUST_ERROR` test that pins
no diagnostic**, with this reasoning in the source:

> A MUST_ERROR that names no diagnostic passes on ANY failure — including one
> wholly unrelated to what it means to pin. That is how a red pin gets marked
> MUST_ERROR and laundered green.

Measured 2026-07-31: **227 `MUST_ERROR` tests, 4 unpinned.** The wall holds at
223/227. So do not open this expecting a rotten corpus — the negative suite is
in good shape, and the 29 are real findings, not bookkeeping.

The four unpinned are your warm-up, and they are already red as `config-error`:

```
100_PARSER/100_083_unclosed_paren_in_capture_value
100_PARSER/100_084_bare_module_call_in_kz_is_host_line
200_COMPILER_FEATURES/210_PARSER/210_029_transform_requires_comptime
300_ADVANCED_FEATURES/330_PHANTOM_TYPES/521_multiple_resources_partial_cleanup
```

A pin can be spelled five ways — `expected_error.txt`, `expected.txt`,
`expected_patterns.txt`, `post.sh`, or a `CONTAINS`/`ERROR_AT` line in `EXPECT`.
Read the predicate at `regression_lib.sh:608-613` before you count anything, and
count with **that** predicate. Two counts made while scoping this frame were
wrong because they used a narrower one.

## The 29, as the board reports them

**`must-error-passed` — it compiles, and it must not (13):**

```
310_102_comptime_obligation_leak
335_020_instance_ambiguous_discharge      335_021_instance_no_explicit_free
335_042_read_file_no_free                 335_043_read_stdin_no_free
335_047_taint_original_reused_after_sanitizer
335_048_taint_original_printed_beside_sanitized
305_subflow_invalid_branch                400_167_prototype_scope_must_not_leak_across_modules
510_116_missing_impl_midchain             510_117_missing_impl_midchain_fabricates_value
610_007_reject_dangling_slice             2104_05_commit_without_close
```

**`wrong-error` — refused, but for the wrong reason (8):**

```
330_118_conserving_tor_is_not_a_disposal_candidate   524_state_variable_constraint_violation
370_020_label_jump_obligation                        520_001_slice_type_imported_module
690_104_undrainable_column_reports_once              690_105_drain_refusal_names_the_composed_type
690_108_drain_discard_names_no_synthetic_binding     2104_21_open_tx_forgot_close
```

**`expected-error-missing` / `no-error-pin` (8):**

```
903_unknown_flag_rejected                 310_039_branch_payload_requires_binding
400_143_effect_branch_borrow_escapes_firing
400_157_effect_inliner_bare_module_name_rejected
510_108_reject_compound_raw_slice_return  510_112_bare_return_impl_uses_branch_ctor
510_113_branch_decl_impl_uses_bare_return 510_114_impl_names_undeclared_branch
```

## Three that already carry their own diagnosis — start here

**`335_047`** names the suspected site in its own header, with line numbers:
`phantom_semantic_checker.zig` `validateArgument` returns early on
`expected_phantom == null` (~:2828), roughly 55 lines **before** the
`context.isDisposed` check that would raise the diagnostic (~:2884). The header's
verdict: *"Disposal is a property of the binding, not of what the consumer
wants — the gate is inverted."* Use-after-discharge fires when a stale binding
flows into another phantom-aware tor, and goes blind when it flows into a
plain-typed consumer like `std/io:print.ln` — which is exactly the sink taint
tracking exists to guard. `335_048` is its sibling, built so the KORU100
unused-binding check cannot incidentally cover it.

**`335_042` / `335_043`** are honest design pins, not bugs. `std/io:read-file`
returns a bare `[]const u8` with no phantom, so the checker has no handle on the
allocation at all. The header says what closes it: an `allocated!` surface on the
IO types. That is a **spelling question** — category 4. Bring it, do not answer
it.

**`510_117_missing_impl_midchain_fabricates_value`** — the compiler fabricates a
value. Whatever else is on this list, that one is a correctness bug in the
emitter, not a checker gap.

## ⚖️ The shootout is the sharp end

`2104_05_commit_without_close` opens a db connection, commits, and never closes
it. It compiles. `2104_21_open_tx_forgot_close` is refused with the wrong error.
These sit in the category we point people at.

Do **not** fix them by editing the examples. Their siblings (`2104_01`,
`2104_02`, `2104_08`, `2104_09`, `2104_18`, `2104_19`, `2104_20`, `2104_22`) are
green and pin the same family, so the shape is supported — the gap is narrow and
locatable by differencing a green sibling against a red one. That diff is the
first thing to run.

## What "done" looks like

- Each of the 29 lands in exactly one of the four buckets, with the evidence that
  put it there.
- Category 1 and 3 are fixed, with a control that was green at HEAD before the
  change.
- Category 2 tests are gone, and the note says why the language never promised it.
- Category 4 is a written list of spelling questions with the reads that raised
  them — the deliverable, not a failure.
- A count of how many of the 29 shared a mechanism. If four of them are one bug,
  that is the finding, and it outranks the individual fixes.

## Failure modes

- **Greening by moving the pin.** Banned outright. `CLAUDE.md`: investigate,
  *then* act.
- **Inventing a spelling** to close a category-4 test. Also banned. Bring the
  question.
- **Fixing the example instead of the compiler.** The 07-30 session's sharpest
  correction was *"`downloads` SHOULDN'T COMPILE because the compiler is broken
  about it."* Same rule here.
- **Reporting a cluster you did not verify.** Two scoping counts for this frame
  were wrong; both were caught by re-deriving from the harness's own predicate
  rather than a plausible one. Re-derive.
