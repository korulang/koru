# 2104_unused_resources

## Important caveat before anything else

This directory has **no `input.kz`**, only `2104_unused_resources/koru/db.kz` — a
database module that is never wired to a driver program. There is no
`MUST_ERROR` marker, no `EXPECT` file, and no `SUCCESS` marker anywhere under
this directory. It is **RED / not a runnable test** in the Koru suite today —
there is no compiled-and-run Koru result to compare against, and nothing below
should be read as implying otherwise. This verdict is this agent's best-effort
Rust encoding of the *intent* stated in `db.kz`'s own doc comment.

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_unused_resources 2104_unused_resources.rs 2>&1
# then:
/tmp/rustcmp_2104_unused_resources
```

## rustc output

Compiled cleanly, no diagnostics (empty stdout/stderr, exit 0).

## Program output (ran it)

```
thread 'main' (253318254) panicked at 2104_unused_resources.rs:101:13:
commit() called on transaction (conn 42) that never called execute() -- resource acquired and formally discharged, but never used meaningfully
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Exit code: 101 (Rust panic).

## What Rust does

Unlike `2104_17`..`2104_22`'s `db.kz`, this module's `begin()` returns `Transaction<active!>` directly — there is no `started!`/`active!` split, so `commit()` is legally callable (by the type signature alone) the instant `begin()` returns, with zero `execute()` calls in between. That means the typestate trick that catches `2104_18`/`2104_19` (separate structs per phantom state) **cannot** catch this: `Transaction` is the same Rust type before and after `execute()`. The only way to catch "committed a transaction that was begun but never used" is a hand-rolled `bool used` field checked explicitly inside `commit()`/`rollback()` — ordinary manual bookkeeping, not something ownership or `Drop` gives for free — and it can only ever be a **runtime** check.

## What Koru does

Unknown for certain — there is no `input.kz` to compile. `db.kz`'s own doc comment states the design intent: *"acquiring a resource creates an OBLIGATION to use it meaningfully. Automatic cleanup (RAII, IDisposable, use statements) doesn't satisfy this — you must actually DO something with the resource."* Whether Koru's compiler actually enforces "must call `execute` before `commit`" for this specific `db.kz` shape is untested — no test exercises it.

## DIFFERS: N/A

There is no Koru compile/run result to diff against. The finding that stands on its own: even Rust's best typestate technique degrades to a hand-written runtime flag for "resource discharged without ever being meaningfully used" — this is the one property in the whole slice that plain ownership/typestate genuinely cannot express at compile time, in any language without dependent/session types. If Koru's phantom system enforces this statically for a `db.kz` shaped this way, that would be a real, distinct Koru win worth a dedicated test — but that test does not exist yet.
