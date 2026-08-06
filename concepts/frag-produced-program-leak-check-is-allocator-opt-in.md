---
type: belief
id: frag-produced-program-leak-check-is-allocator-opt-in
provenance: measured 2026-07-24; reframed by Lars's ruling the same night — a proc may name its own allocator. 2026-08-06: the predicted class landed in koru_std, and the double-free the fragment left open turned out to be reachable in six lines of ordinary Koru.
ts: 2026-08-06
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
counter when the memory is author-owned.

**This is an OPEN QUESTION, not a settled cost.** The ruling above is narrow —
a proc may name its own allocator — and it says nothing about whether these two
classes deserve a mechanism. An earlier draft of this fragment inferred from
"procs are unsafe" that a double-free is therefore acceptable, and attributed
that inference to Lars. He did not rule it. `unsafe` names where the
responsibility sits; it is not a decision to stop detecting anything.

## 2026-08-06 — the predicted class landed, and it was OURS, not an author's

The ruling above narrows the concern to one bug class: *an uninstrumented
allocation hiding a bug in the TOOLCHAIN*. That class was hypothetical when it
was written. It is not any more, and it was worse than the framing anticipated in
one specific way — **the leaking code was `koru_std`, not a user's `proc`.**

`HandlePool.deinit` freed its `ArrayList` and leaked all seven strings `acquire`
dupes per handle. It had done so since it was written. Nobody saw it because
every caller in the corpus constructed the pool on `std.heap.page_allocator` —
the two `440` tests hand-roll `HandlePool.init(std.heap.page_allocator)` in raw
Zig, and the interpreter's own local pool comes off a page-backed arena. The
first pool ever built on `koru_allocator()` — a `std/bridge` session, whose
allocator is the produced program's — failed the leak check on its first run, and
the count named the size exactly (three for the session, eight more for one
handle).

So the mechanism works and the coverage is the whole story. What the earlier
analysis got right: instrumentation is opt-in and a leak outside it is unseen.
What it did not anticipate: **the stdlib opts out too, and when it does, the
"author-owned memory is the author's problem" framing stops applying** — nobody
authored that leak in a `proc`, and no output diff could show it, because a
leaked string prints nothing.

The sharpened rule: **an allocator choice is a decision about who can see your
bugs, and in library code it is a decision made on behalf of every caller.** A
`proc` author picking `page_allocator` is exercising the escape hatch as ruled.
A stdlib type picking it — or accepting one and never being handed the tracked
one — silently exempts an entire subsystem from the only detector that exists.

What this leaves: the `HandlePool` case is fixed, but it was found by accident,
by being the first caller to wire the tracked allocator through. Nothing counts
which `koru_std` types are reachable only on uninstrumented allocators, and that
census is the actual instrument this belief has been asking for since July.

## 2026-08-06, later — the open double-free question has a witness, and the
## comment that closed it was wrong

The section above lists a double-free as "Open, and NOT covered by that", and
ends by insisting it is **an open question, not a settled cost**, because an
earlier draft had inferred acceptance from "procs are unsafe" and attributed
that inference to Lars, who never ruled it.

It is worse than open. It was **already answered in the negative, in the
compiler's own source, as the justification for the allocator move**:

> *"What this trades away: DebugAllocator's double-free/invalid-free detection
> at the allocator layer — Koru's primary defense there is already the phantom
> obligation system (double-free is a COMPILE-TIME error for well-typed
> programs), so this is a backstop loss, not a loss of the language's actual
> safety guarantee."* — `src/emitter_helpers.zig`

That sentence is false, and the program that falsifies it is six lines: a tor
takes a subject as a bare `<issue>` — a borrow, which does not consume — and
returns the very same pointer carrying `<issue!>`. One object, two obligations,
both paid, `exit 134`. Pinned `335_053`. The corpus held **zero** double-free
tests, so the guarantee that bought the trade had never been checked even once.

## The shape, which is not what any of us guessed

The phantom system is affine over BINDINGS. It has no notion that two bindings
can name one VALUE. Everything downstream follows from that single absence:

- return the borrowed subject with a fresh obligation → two debts, one object
- return it bare → an alias owing nothing, which `<!state>` accepts anyway
- return a field of it as a plain `string` → an alias with no phantom at all,
  which is `610_007` and reads freed memory

Three faces, one cause. **The mechanism is real and it is doing exactly what it
says; the claim built on top of it over-read its reach.** A system that tracks
"this binding must be used once" was described as if it tracked "this object is
freed once", and those coincide only while no two bindings alias.

The methodological residue is the part worth keeping: **a safety claim written
into a comment as the justification for removing a check is the highest-value
thing in a repo to test, and the least likely to be tested** — because the
comment reads as a citation of a guarantee rather than as a claim making one.
Nothing in the corpus was addressed to it. The comment was persuasive, correct
about the mechanism it named, and load-bearing for a decision.
