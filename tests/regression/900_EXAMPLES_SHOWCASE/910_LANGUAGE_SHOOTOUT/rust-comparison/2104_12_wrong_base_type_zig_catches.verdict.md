# 2104_12_wrong_base_type_zig_catches

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_12 2104_12_wrong_base_type_zig_catches.rs

**rustc output (verbatim):**

```
error[E0599]: no method named `close` found for struct `Transaction<S>` in the current scope
  --> 2104_12_wrong_base_type_zig_catches.rs:70:7
   |
36 | struct Transaction<S> {
   | --------------------- method `close` not found for this struct
...
70 |     t.close();
   |       ^^^^^ method not found in `Transaction<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Did not run (compilation failed).

**Rust:** this file is deliberately the same program as 2104_10 — there is no Rust flag to disable base-type checking, so there is nothing to demonstrate a difference against. As a side probe (`/tmp/rustcmp_probe_unsafe.rs`, `/tmp/rustcmp_probe_unsafe2.rs`, run by hand, not part of the deliverable): an ordinary function call `close(&t)` where `close` takes `&Connection` and `t: Transaction` is rejected outright with `error[E0308]: mismatched types`, no generics or typestate needed at all; the *only* way to make it compile is `let c: &Connection = unsafe { std::mem::transmute(&t) };`, which compiles with just a dead-code warning and then runs, silently passing the wrong value.

**Koru:** without `--strict-base-types` (this test's setting), Koru's own phantom checker only compares state tags (`active` == `active`) and lets the mismatched call through to codegen; the mistake is caught only because the emitted Zig code still has two distinct real structs, and Zig's compiler refuses with: `expected type '*output_emitted.koru_app.koru_db.Connection', found '*output_emitted.koru_app.koru_db.Transaction'`.

**DIFFERS: yes** — not in the outcome (both refuse the program), but in the architecture behind it. Koru has two gates here — an opt-in front-end phantom checker, and a fallback on whatever the Zig backend happens to enforce when that's off — and its default posture (no flag) relies entirely on the second gate, producing a diagnostic that leaks internal codegen module paths (`output_emitted.koru_app.koru_db.*`). Rust has one gate, always on: ordinary nominal typing. Reaching Koru's default exposure window in Rust requires deliberately writing `unsafe`; Koru reaches it by simply omitting a flag.

## UPDATE 2026-08-10 — the Koru side of this row changed

Writing this comparison is what surfaced the defect described above, and it is
fixed. Base-type checking no longer sits behind `--strict-base-types`; the flag
is deleted and the check is unconditional. Koru now refuses this program in its
own front end with its own diagnostic:

```
error[KORU030]: Type mismatch: expected 'app.db:*Connection<!active>' but got 'app.db:*Transaction<app.db:active!>' for argument 'conn'
```

The verdict text above is preserved as written — it records what was true when
measured, and the Rust-side probes in it are unaffected.
