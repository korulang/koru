# 2104_02_uncommitted_tx

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_02 2104_02_uncommitted_tx.rs
```

**rustc output (verbatim):**
```
warning: trait `UsableForExec` is never used
  --> 2104_02_uncommitted_tx.rs:48:7
   |
48 | trait UsableForExec {}
   |       ^^^^^^^^^^^^^
   |
   = note: `#[warn(dead_code)]` (part of `#[warn(unused)]`) on by default

warning: method `exec` is never used
   --> 2104_02_uncommitted_tx.rs:137:8
    |
136 | impl<S: TxDrop + UsableForExec> Transaction<S> {
    | ---------------------------------------------- method in this implementation
137 |     fn exec(mut self, sql: &str) -> Result<Transaction<Active>, String> {
    |        ^^^^

warning: method `commit` is never used
   --> 2104_02_uncommitted_tx.rs:145:8
    |
144 | impl Transaction<Active> {
    | ------------------------ method in this implementation
145 |     fn commit(mut self) -> Result<Connection<Active>, String> {
    |        ^^^^^^

warning: method `close` is never used
   --> 2104_02_uncommitted_tx.rs:160:8
    |
159 | impl Connection<Active> {
    | ----------------------- method in this implementation
160 |     fn close(mut self) -> Result<(), String> {
    |        ^^^^^

warning: 4 warnings emitted
```
Compiled successfully (only dead-code warnings for the state machine's
happy-path methods, which this specific program never reaches because it
panics first). Exit code: 0.

**Program output (`/tmp/rustcmp_2104_02`, exit 101):**
```
thread 'main' panicked at 2104_02_uncommitted_tx.rs:82:13:
Transaction<started!> obligation not discharged before drop (Koru: "was not disposed. Call: exec")
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

**What Rust does:** `begin()` returning a `Transaction<Started>` that is
immediately matched with `Ok(_) => {}` (never `exec`'d) is not ill-typed —
`Transaction<Started>` is a perfectly legal value to hold and drop — so the
program compiles cleanly. The same "drop bomb" technique as 2104_01 catches
it at runtime: `Transaction`'s `Drop` impl panics because `exec()`, the only
method that disarms it, was never called.

**What Koru does:** refuses to compile — `MUST_ERROR: "was not disposed.
Call: exec"` (`EXPECT: CONTAINS <started!> was not discharged`).

**DIFFERS: yes** — same shape as 2104_01: Koru catches the un-exec'd
transaction statically; Rust's ownership rules alone don't see a problem, so
the mistake only surfaces when the value drops at runtime.
