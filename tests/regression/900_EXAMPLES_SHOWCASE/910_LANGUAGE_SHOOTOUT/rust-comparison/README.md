# The same 23 programs, in Koru and in Rust

Every program in `2104_*` is a database connection and transaction being used —
correctly, or in one of the ways people get it wrong. Each one was written a
second time in Rust, then **compiled and run**. The per-case files beside this
one carry the command, the compiler's output word for word, and the exit code.
Nothing here is quoted from memory.

The Rust translations use plain typestate: one zero-sized marker type per phase,
methods implemented only on the phase where they are legal. No macros, no
`unsafe`, no crates. Where Rust needed something a Rust programmer would not
normally write, the case says so.

## The scoreboard

Twenty-two of the twenty-three directories are tests with a Koru result to
compare against. (`2104_unused_resources` is a shared module, not a test — see
the bottom of this page.)

| | cases |
|---|---|
| **Koru refuses the program; Rust builds it and it crashes when run** | 5 |
| **Both compilers refuse it** | 8 |
| **Both compilers accept it and it behaves the same** | 9 |

### The five that carry the claim

Koru will not produce a binary. Rust produces one, and the mistake surfaces only
when the program is actually running — and only because these translations carry
a hand-written guard that panics on drop.

| case | the mistake |
|---|---|
| `01_unused_connection` | connection opened, never used |
| `02_uncommitted_tx` | transaction begun, never finished |
| `20_open_tx_abandoned` | transaction abandoned mid-flight |
| `21_open_tx_forgot_close` | connection left open |
| `22_open_tx_exec_no_finish` | work done, never committed or rolled back |

The obvious rebuttal is `#[must_use]`, and it does not hold. It was probed
directly: `let _ = expr;` — which is the natural translation of Koru's own
discard — **suppresses the lint entirely, even under
`#![deny(unused_must_use)]`**. Compiles clean, exit 0. See
`2104_20_open_tx_abandoned.verdict.md`.

### The eight draws, and they matter more than the wins

Both compilers refuse these, at compile time, and Rust does it with the pattern
any experienced Rust developer already reaches for.

| case | the mistake |
|---|---|
| `08_close_without_transaction` | closing a connection that never began one |
| `09_empty_transaction` | committing a transaction nothing ran in |
| `10_wrong_base_type` | passing a transaction where a connection goes |
| `11_wrong_base_type_reverse` | the reverse of `10` |
| `12_wrong_base_type_zig_catches` | `10` again, with Koru's base-type check off |
| `13_wrong_base_type_reverse_zig_catches` | `11` again, same |
| `18_open_tx_empty_commit` | committing straight after beginning |
| `19_open_tx_close_early` | closing straight after opening |

`08` is the cleanest of them: `close()` implemented only for a connection that
has a transaction on it, so `rustc` says `E0599: no method named close found for
struct Connection<Connected>`. That is precisely the mistake the obligation
checker exists to catch, caught for free.

### The nine both accept

`03`, `04`, `05`, `06`, `07`, `14`, `15`, `16`, `17` — the correct programs, plus
the ones where cleanup happens without being written out. Both sides produce the
same trace. In five of these the Koru side's recorded output was diffed against
the Rust program's actual output byte for byte.

## Two rows that do not flatter us, and should be read

**`12` and `13` are draws in outcome and losses in architecture.** Both
compilers refuse the program. But Koru's own front end does not: with the
base-type check off — which is this test's setting, and the default — the
phantom checker sees two matching state tags and lets the wrong call through to
code generation. The thing that actually refuses it is the Zig the compiler
emitted, and the message the author reads is Zig's, naming Koru's internal
generated module paths:

```
expected type '*output_emitted.koru_app.koru_db.Connection',
   found '*output_emitted.koru_app.koru_db.Transaction'
```

Rust has one gate and it is always on. Getting Rust to behave the way Koru
behaves by default takes a deliberate `unsafe { transmute }` — that probe is in
`2104_12`'s file.

**`15` is Rust's strongest row.** Koru needed dedicated compiler behaviour to
insert a `close()` on a dropped obligation. Rust's `Drop` gives the identical
guarantee as an ordinary consequence of ownership, with no feature built for the
purpose.

## The one thing that was never tested

`2104_unused_resources` contains a module and no program. Its own comment states
the strongest version of the whole thesis — *acquiring a resource creates an
obligation to use it meaningfully, and automatic cleanup does not satisfy that* —
and there is no Koru file compiling against it, so the claim is unpinned. The
Rust side established that this property is the one thing plain typestate
genuinely cannot express at compile time in any language without dependent or
session types; it degrades to a hand-written `bool used` flag checked at runtime.
If Koru enforces it statically, that is a distinct result and it needs a test
that does not exist yet.

## The line the whole thing reduces to

> Rust proves you cleaned up, and proves you used the thing in the right order.
> It cannot prove you used it at all.
