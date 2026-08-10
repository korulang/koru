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
| `12_wrong_base_type_zig_catches` | `10` again — the directory name is now stale, see below |
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

## What this comparison found, and what it closed

**`12` and `13` were losses when this page was first written, and the writing of
it is what surfaced them.** Both compilers refused the program, so the outcome
was a draw — but Koru's own front end did not do the refusing. Base-type
checking sat behind an opt-in flag, off by default, so the phantom checker saw
two matching state tags and passed the wrong call to code generation. What
actually refused it was the emitted Zig, and the message the author read was
Zig's, naming Koru's internal generated module paths. Both tests pinned that Zig
text as their expected diagnostic — the fallback promoted to a specification.

**Fixed 2026-08-10.** The check runs unconditionally now and the flag is gone;
both tests pin a Koru diagnostic naming Koru types. The reason the flag existed
turned out not to be the stated one (deferring to Zig for accuracy on type
aliases). Forcing the old comparison on for a full board produced 5 false
positives and every one was a single defect: it compared *module-qualified*
forms, and the qualifier is stamped on with whichever module happens to be
writing, so both sides named the identical type and disagreed on its prefix.
Three of the five qualified a primitive, where a module prefix is meaningless
outright. Comparing unqualified names refuses every genuine mismatch with none
of the false positives.

Rust still has the cleaner story here in one respect worth keeping: one gate,
always on, no flag ever existed. Getting Rust to reach the exposure window Koru
used to have by default takes a deliberate `unsafe { transmute }` — that probe
is in `2104_12`'s file and is still the sharpest thing in it.

**`15` is Rust's strongest row, and it stands.** Koru needed dedicated compiler behaviour to
insert a `close()` on a dropped obligation. Rust's `Drop` gives the identical
guarantee as an ordinary consequence of ownership, with no feature built for the
purpose.

## The strongest claim in the corpus, and how it is held

*Acquiring a resource obliges you to use it meaningfully; automatic cleanup does
not satisfy that.* This is the one property the Rust side established that plain
typestate genuinely cannot express at compile time in any language without
dependent or session types — it degrades to a hand-written `bool used` flag
checked at runtime.

Koru enforces it statically, and the mechanism is an **asymmetry deliberately
built into the state chain**: there is no path from creating a resource to
releasing it that does not pass through using it.

```
tx.begin  { conn: *Connection<!connected|!active> } -> *Transaction<started!>
tx.exec   { tx: *Transaction<!started|!active>, … } -> *Transaction<active!>
tx.commit { tx: *Transaction<!active> }             -> *Connection<active!>
```

`begin` hands back `started!`. `commit` demands `active!`. Only `exec` turns one
into the other. So a transaction that was opened and closed without any work in
between is not a lint, a warning, or a runtime check — it is a state that cannot
be spelled.

Two tests hold it, both `MUST_ERROR` on `Phantom state mismatch`:
`2104_09_empty_transaction` and `2104_18_open_tx_empty_commit`. On the Rust side,
`18` is the one place typestate keeps up — two structs, `commit()` implemented
only on the second — and it is in the draws table above.

### `2104_unused_resources` is the exception, and it is dead weight

That directory holds a module and no program. Its `db.kz` is an older, weaker
shape: `begin()` returns `Transaction<active!>` directly, with no `started!`
phase, so `commit()` is legally callable the instant the transaction exists. The
asymmetry above is simply absent. It cannot express the claim its own doc comment
makes, and nothing compiles against it — so it demonstrates nothing and should
either be brought up to the split shape or removed.

## The line the whole thing reduces to

> Rust proves you cleaned up, and proves you used the thing in the right order.
> It cannot prove you used it at all.
