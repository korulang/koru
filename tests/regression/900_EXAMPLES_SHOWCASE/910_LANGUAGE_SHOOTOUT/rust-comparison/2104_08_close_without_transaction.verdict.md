# 2104_08_close_without_transaction

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_08 2104_08_close_without_transaction.rs
```

**rustc output (verbatim):**
```
error[E0599]: no method named `close` found for struct `Connection<Connected>` in the current scope
   --> 2104_08_close_without_transaction.rs:179:23
    |
104 | struct Connection<S: ConnDrop> {
    | ------------------------------ method `close` not found for this struct
...
179 |             let _ = c.close();
    |                       ^^^^^ method not found in `Connection<Connected>`
    |
    = note: the method was found for
            - `Connection<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```
Compilation FAILED. Exit code: 1. Program never built, so it never ran.

**What Rust does:** `close()` is only implemented in the `impl
Connection<Active>` block; there is no `impl` providing it for
`Connection<Connected>` (a freshly-connected, never-begun connection). The
type checker rejects the call outright, at compile time, with no runtime
component at all — no drop bomb, no panic, just an ordinary "no method
named `close` found" error, the same error a Rust programmer gets from any
garden-variety typo or type mix-up.

**What Koru does:** refuses to compile — `MUST_ERROR: "state mismatch"`
(`EXPECT: CONTAINS Phantom state mismatch`) — because `close()` requires
`Connection<!active>` and `c` is `Connection<connected!>`.

**DIFFERS: no** — both refuse to compile this program. This is the
standout case in the 01–08 slice: Rust's ordinary method-resolution rules,
applied to a typestate encoding, catch the exact same "phantom state
mismatch" Koru's dedicated obligation checker exists to catch — with no
special-purpose machinery (no drop bombs, no unsafe, no macros), just the
compile-time typestate pattern any experienced Rust developer already
reaches for.
