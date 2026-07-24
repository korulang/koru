---
type: belief
id: frag-produced-program-leak-check-is-allocator-opt-in
provenance: measured 2026-07-24; reframed by Lars's ruling the same night — a proc may name its own allocator, the question is only whether a TOOLCHAIN bug can hide
ts: 2026-07-24
---

# The produced-program leak counter is opt-in, and that is correct — the real question is whether a toolchain-caused missing discharge is observable (belief)

The harness checks the final artifact, not only the compiler. Three phases grep
Zig's GPA wording (`memory address … leaked`) across `compile_kz.err`,
`compile_backend.err` and `backend.err`; a fourth greps the produced program's
own output for `KORU LEAK CHECK FAILED`, with its own failure category that
outranks the output diff. The emitted `main()` counts traffic through
`koru_allocator()` and exits 1 when the count is non-zero. All four are live —
verified by an A/B on one Koru source: with the proc body on
`std.heap.page_allocator` the leak exits 0 silent, on `koru_allocator()` the
same leak exits 1 and is caught.

## Lars's ruling: this is not a language problem

**A `|zig` proc may name its own allocator.** `proc` is the unsafe escape hatch;
Zig is supposed to do Zig things inside it. A wall rejecting raw allocators, or
interposition removing the choice, would constrain the escape hatch to make our
measurement convenient — which defeats the point of having one. Author-owned
memory is the author's to manage, and a leak they cause in unsafe code is their
bug, not a gap in Koru's guarantee.

The concern is narrower and sharper: **it matters only where an uninstrumented
allocation can hide a bug in the TOOLCHAIN.** The bug class that counts is Koru
promising a discharge — auto-discharge insertion, obligation enforcement — and
then failing to emit it. That failure shows up as author-owned memory never
freed, so the leak counter cannot see it regardless of what we do to `proc`.

## Which means the detection mechanism is the output diff, and it mostly works

A missing discharge is observable without any allocator instrumentation, because
the disposer prints. A fixture whose `expected.txt` contains its disposal line
("Connection closed", "Closing file") fails the output diff the moment the
toolchain stops emitting the call. That is more direct than a leak counter — it
names the missing act rather than the residue.

Measured over `330_PHANTOM_TYPES`, of the 96 fixtures on a raw allocator:

- 33 are `MUST_FAIL` — they never execute; runtime leak detection is moot
- 36 execute AND assert the discharge in `expected.txt` — covered
- **27 execute with no discharge assertion** (2 are shared `lib` dirs, so 25 tests)

That residue is the whole finding. An earlier draft of this belief claimed ~97
blind fixtures and proposed the language-wall fork; both were wrong — the count
ignored `MUST_FAIL` and the output-diff mechanism entirely, and the fork attacked
`proc` for a problem `proc` does not have.

## The work this leaves

Give the 27 a discharge assertion in `expected.txt`. Test hygiene, no language
change, no user-facing migration, and it closes the observable gap for the bug
class that matters. Notable that `330_101`–`330_108` (the field-narrowing pins)
are in the set — the newest obligation work is the least watched at runtime.

Open, and NOT covered by that: a double-free, and a leak on a path that prints
nothing. Neither is caught by the output diff, and neither is caught by the
counter when the memory is author-owned. Whether that residue is worth a
mechanism is unruled — it may simply be the accepted cost of an unsafe escape
hatch, which is the correct place for it to live.
