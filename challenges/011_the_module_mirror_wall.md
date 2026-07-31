---
challenge: module-mirror
kind: frame
status: standing
yields: every stdlib comptime construct works inside a module, or refuses with a diagnostic that says why
family: comptime
---

*Walker context — the recurrence that earned this frame. `115_COMPTIME_MIRROR`
exists to ask one question of every comptime construct in the stdlib: does it
still work when the program that uses it lives in a module rather than at the top
level? As of 2026-07-31 the category is **18 red out of 38** — a coin flip — and
seventeen of the eighteen die the same way, at `backend-exec`.*

*Read the failing names in one column and the shape is unmissable:*

```
115_003_regex_scan_in_module          115_013_regex_match_in_module
115_004_field_new_in_module           115_029_field_mark_multiples_in_module
115_005_kernel_init_in_module         115_016_kernel_self_in_module
115_027_kernel_pairwise_in_module     115_028_kernel_step_in_module
115_012_parser_grammar_in_module      115_036_runtime_register_in_module   (output)
115_018_store_insert_in_module        115_019_store_query_in_module
115_020_store_sweep_in_module         115_021_store_watch_in_module
115_022_store_stripe_in_module        115_023_store_take_in_module
115_038_trellis_enforce_in_module     115_039_trellis_check_in_module
```

*Six subsystems — regex, field, kernel, parser, store, trellis — each with a
different author, a different transform, and a different year. They do not share
code. They share a **fault**. That is what makes this frame worth running as one
piece of work instead of eighteen.*

---

## The brief (sealed — you are the contestant)

Find out whether the eighteen are **one bug, a few bugs, or eighteen bugs.**
Answer that with evidence before fixing anything. Then close whichever of them
share a mechanism, and leave the rest individually diagnosed.

The finding — *how many mechanisms* — is worth more than the greens.

## Ground yourself FIRST

**Read `idea_comptime_authoring_surface` in memory before you start.** This frame
is the "module-mirror test wall FIRST" move that idea already ruled, sitting
unstarted. It also carries the ordering: mirror wall, then `site`, then the
sweep of 55. Do not re-derive that order; it was already argued.

**Then read the green half.** Twenty of the 38 pass. The passing tests are the
control group and they are the whole method here: whatever a green
`*_in_module` test does that a red one does not is the entire diagnosis. Start
by differencing one green against one red in the **same** subsystem if such a
pair exists, and across subsystems if it does not.

**Then check the four-stage pipeline.** `zig build` does **not** catch errors in
`koru_std` — `store.kz` is compiled by the metacircular backend, so a green build
means almost nothing here. That trap has bitten before; it is in the
`koru-toolchain` skill and it will bite again if you use build success as a
signal.

## The pre-garden — are these tests any good?

Before trusting the eighteen as a work list, audit them as tests. Specifically:

- **Is each `_in_module` test actually the module twin of a top-level test?** The
  category's value rests entirely on that pairing. If `115_020_store_sweep_in_module`
  does not mirror a real green top-level sweep test, it is pinning a shape nobody
  ever supported, and it belongs in a different bucket.
- **Do they differ only in module placement?** If a mirror test also changed the
  program, it is testing two things and its red says nothing clean.
- **Is `115_036_runtime_register_in_module` in the right category at all?** It is
  the one failing at `output` rather than `backend-exec`, and `runtime` is a
  parked subsystem (see `010`-family framing and `project_runtime_interpreter_parked`).
  It may be red for a reason that has nothing to do with modules.

Report what you find about the tests themselves even if it shrinks the work list.
A category that is 18-red because 3 of the tests are malformed is a **better**
outcome than 18 speculative fixes, and it is a finding either way.

## Where the fault probably is not

Do not assume the six subsystems have a common call path — they mostly do not.
`store.kz`, `kernel.kz`, `regex.kz`, `field.kz`, `parser.kz` and `trellis.kz` are
separate transforms. What they share is the **environment** a transform runs in,
and the plausible common ground is:

- name resolution when the program has a module qualifier in scope,
- the compilation root a transform anchors filesystem or symbol lookups against
  (there is a standing rule here: *a transform's FS anchor is the compilation
  root, never `dirname(location.file)`* — see `baton_std_vendor_compile_time_pin`),
- pass ordering, which is a live and repeatedly-implicated mechanism — see the
  Tier-1 entry in `baton_store_red_pin_queue`,
- the two module-name domains (file `lib` vs import `app.lib`) recorded in
  `baton_implicit_expr_slot_and_store_module_home`.

Those are hypotheses to test, not conclusions to adopt. Test them by
instrumenting one failing case end to end, not by reading all six transforms.

## ⚖️ Eighteen greens is not the win condition

The win is the **wall**. If eighteen tests can quietly break for one reason, the
category can silently re-break the moment a seventh subsystem is added without a
mirror test. So the deliverable includes:

- a check that every comptime construct exposed by `koru_std` **has** a mirror
  test, failing loudly when one is added without one, and
- the count of constructs currently exposed versus mirrored. If the stdlib
  exposes 22 comptime transforms and 38 mirror tests cover 19 of them, name the
  three that nobody is watching.

That number — constructs with no mirror test — is the finding this frame most
wants, because those are the ones that cannot even go red.

## What "done" looks like

- A mechanism count, with evidence: *"these eleven are one fault at X; these four
  are a second at Y; these three are individually distinct."*
- Whatever share a mechanism, fixed together, with controls green at HEAD first.
- The remainder diagnosed individually, red, and honest about it.
- A wall that fails when a comptime construct ships without a mirror test.
- Any spelling question written down, not answered.

## Failure modes

- **Fixing eighteen tests eighteen times.** If they share a fault and you close
  them one at a time, the frame produced greens and no knowledge.
- **Trusting `zig build`.** It does not compile `koru_std` the way the suite does.
- **Skipping the green half.** The controls are the diagnosis.
- **Running the full board to check progress.** ~11 minutes, and it is for
  publishing. Run `./run_regression.sh 115_003_... 115_004_...` plus controls.
