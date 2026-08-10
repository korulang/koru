# 2104_11_wrong_base_type_reverse

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_11 2104_11_wrong_base_type_reverse.rs

**rustc output (verbatim):**

```
error[E0599]: no method named `commit` found for struct `Connection<S>` in the current scope
  --> 2104_11_wrong_base_type_reverse.rs:58:7
   |
19 | struct Connection<S> {
   | -------------------- method `commit` not found for this struct
...
58 |     c.commit();
   |       ^^^^^^ method not found in `Connection<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Did not run (compilation failed).

**Rust:** the mirror image of 2104_10 — `commit` is a method that exists only in `impl Transaction<Active>`, and `Connection<Active>` (same layout, same phantom state name) simply doesn't have it. Same mechanism, opposite direction, no flag.

**Koru:** with `--strict-base-types`, refuses with `error[KORU030]: Type mismatch: expected 'app.db:*Transaction<!active>' but got 'app.db:*Connection<app.db:active!>' for argument 'tx'`.

**DIFFERS: no** — same bug caught at compile time in both.
