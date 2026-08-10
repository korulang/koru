# 2104_01_unused_connection

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_01 2104_01_unused_connection.rs
```

**rustc output (verbatim):**
```
warning: field `handle` is never read
  --> 2104_01_unused_connection.rs:24:5
   |
23 | struct Connection {
   |        ---------- field in this struct
24 |     handle: i32,
   |     ^^^^^^
   |
   = note: `#[warn(dead_code)]` (part of `#[warn(unused)]`) on by default

warning: field `conn_handle` is never read
  --> 2104_01_unused_connection.rs:29:5
   |
28 | struct Transaction {
   |        ----------- field in this struct
29 |     conn_handle: i32,
   |     ^^^^^^^^^^^

warning: method `begin` is never used
  --> 2104_01_unused_connection.rs:43:8
   |
38 | impl Connection {
   | --------------- method in this implementation
...
43 |     fn begin(mut self) -> Result<Transaction, String> {
   |        ^^^^^

warning: method `commit` is never used
  --> 2104_01_unused_connection.rs:70:8
   |
60 | impl Transaction {
   | ---------------- method in this implementation
...
70 |     fn commit(mut self) -> Result<(), String> {
   |        ^^^^^^

warning: 4 warnings emitted
```
Compiled successfully (only dead-code warnings — the code paths reached only by
a properly-discharged connection/transaction are unreachable in this specific
program, since it panics before ever calling them). Exit code: 0.

**Program output (`/tmp/rustcmp_2104_01`, exit 101):**
```
thread 'main' panicked at 2104_01_unused_connection.rs:52:13:
Connection<open!> obligation not discharged before drop (Koru: "[open!] was not discharged. Call: app.db:begin")
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

**What Rust does:** Rust's ownership/borrow checker has nothing to say about a
value that is constructed, matched with `Ok(_) => {}`, and dropped without
being used further — that is completely ordinary, legal Rust — so the file
compiles cleanly; the mistake is only caught at runtime, by a hand-written
"drop bomb" (`Connection`'s `Drop::drop` panics because `begin()`, the only
method that would have disarmed it, was never called).

**What Koru does:** refuses to compile — `MUST_ERROR: "[open!] was not
discharged. Call: app.db:begin"` (`EXPECT: CONTAINS <open!> was not
discharged`).

**DIFFERS: yes** — Koru rejects this program before it ever runs; Rust
accepts it and only catches the same mistake when the value is dropped at
runtime (here, immediately). Both ultimately refuse to let a connection sit
unused, but at different times: Koru's obligation checker is static, Rust's
best available analogue (a panic-on-drop guard, the same pattern crates like
sqlx use for uncommitted transactions) is dynamic.
