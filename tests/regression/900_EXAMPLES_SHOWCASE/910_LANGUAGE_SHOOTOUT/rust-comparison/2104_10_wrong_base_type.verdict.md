# 2104_10_wrong_base_type

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_10 2104_10_wrong_base_type.rs

**rustc output (verbatim):**

```
error[E0599]: no method named `close` found for struct `Transaction<S>` in the current scope
  --> 2104_10_wrong_base_type.rs:65:7
   |
31 | struct Transaction<S> {
   | --------------------- method `close` not found for this struct
...
65 |     t.close();
   |       ^^^^^ method not found in `Transaction<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Did not run (compilation failed).

**Rust:** `Connection` and `Transaction` are two distinct `struct`s — identical field layout (`{ handle: i32 }`) and identical phantom state name (`Active`) are both irrelevant to Rust's type checker, which only ever looks at the declared nominal type; `close` isn't a method `Transaction` has, full stop, no flag required.

**Koru:** with `--strict-base-types`, refuses with `error[KORU030]: Type mismatch: expected 'app.db:*Connection<!active>' but got 'app.db:*Transaction<app.db:active!>' for argument 'conn'`.

**DIFFERS: no** — same bug caught at compile time in both, but Rust needed no equivalent of `--strict-base-types` to get there; see 2104_12 for why that flag exists at all in Koru.
