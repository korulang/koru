# 2104_13_wrong_base_type_reverse_zig_catches

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_13 2104_13_wrong_base_type_reverse_zig_catches.rs

**rustc output (verbatim):**

```
error[E0599]: no method named `commit` found for struct `Connection<S>` in the current scope
  --> 2104_13_wrong_base_type_reverse_zig_catches.rs:60:7
   |
22 | struct Connection<S> {
   | -------------------- method `commit` not found for this struct
...
60 |     c.commit();
   |       ^^^^^^ method not found in `Connection<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Did not run (compilation failed).

**Rust:** the reverse-direction mirror of 2104_12 and, again, the same program as 2104_11 — Rust has no "loose" mode to place this test in, so it's the identical rejection through the identical mechanism (no `commit` method on `Connection<Active>`).

**Koru:** without `--strict-base-types` (this test's setting), Koru's phantom checker again only sees matching state tags and lets the call through; the emitted Zig code's real, distinct struct types are what actually refuse it: `expected type '*output_emitted.koru_app.koru_db.Transaction', found '*output_emitted.koru_app.koru_db.Connection'`.

**DIFFERS: yes**, for the same architectural reason as 2104_12: Koru's default mode depends on the Zig backend as a second gate and leaks its internal type paths in the diagnostic when that gate is what fires; Rust never needed a second gate because its single front end already does full nominal typing on every call, unconditionally — see 2104_12's verdict for the `unsafe`-transmute probe that shows exactly what it would take to make Rust behave like Koru's default here.
