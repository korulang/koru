# Challenge 008 — The comptime transform catalog

> Write a **comptime transform** nobody has written yet, pin it with a regression test, and
> report the friction in two buckets. The transform is the artifact; the **friction report is
> the point**. Each replay grows a catalog of working transforms *and* a dataset naming what
> the comptime surface is missing — sorted into what a library could hand you versus what only
> a language contract can.

This is a standing **generative frame**, not a backlog. There is no list of transforms to work
down; each run re-derives a fresh one from the live surface and the existing catalog. Run it
repeatedly — it is a flywheel.

**You are the contestant.** Do not ask which transform to build. Pick one, name it, ship it.

---

## Why this challenge exists

Koru's pitch is *you are the compiler*. Every transform that exists today was written by the
people who built the compiler, and they know where the bodies are buried. The surface has never
been met by someone who didn't already know it. You are that person. What you stumble over is
the finding — more than whatever you build.

Audited 2026-07-25: getting **in** to a transform is well-designed (see the contract below).
What's missing is everything **after** you arrive. `koru_std/store.kz` scans `prog.items` by
hand **forty times**, carries **nine** private helper structs, and says so in its own source at
line 108: *"each transform carries its own H, as the rest of this file does."*

---

## The contract — what a transform actually is

All of this is read off green tests and `koru_std`. It is **not** a design sketch; ground any
extension of it the same way, or label it a guess.

A transform is two declarations: a `tor` that names it, and a `|zig` proc that implements it.

    ~[comptime|transform]pub tor <name> { <params> } -> SiteResult
    ~[transform]proc <name>|zig { ... }

**Modifiers in live use** — `comptime`, `transform`, `keyword`, `pre`, `pure`,
`claims_descendants`. If you need a behaviour none of these give you, **that is a finding**;
write it in the friction report rather than working around it quietly.

**Parameters are a request, not a fixed signature.** Declare what you need and the compiler
injects it. The seven the corpus actually uses, with their usage counts:

| parameter | uses |
|---|---|
| `item: *const Item` | 65 |
| `program: *const Program` | 65 |
| `expr: Expression` (also `?Expression`) | 62 |
| `allocator: std.mem.Allocator` | 38 |
| `invocation: *const Invocation` | 32 |
| `source: Source` | 16 |
| `event_name: string` | 7 |

Your transform's **own** arguments are declared the same way and arrive the same way —
`grammar: Expression`, `bits: usize`, `guard: Expression` are all real examples in the corpus.
One mechanism for both.

**Return `SiteResult`** — universally, across all 85 declarations surveyed. Replace the site,
or decline:

    return .{ .replacement = ast.Item{ .inline_code = .{ ... } } };   // replace
    return .{};                                                       // no-op

**Read `tests/regression/200_COMPILER_FEATURES/220_COMPILATION/220_013_many_transforms_no_cap/input.kz`
before you start.** It is green, it is self-contained, and it is the smallest complete example
of the whole contract. Twenty transforms in one file, no build wiring, no `koru_std` membership.

---

## Ground yourself against the catalog FIRST

Before you build anything, read what is already there:

    ls tests/regression/800_CHALLENGES/
    grep -rl "\[.*transform.*\]" tests/regression --include="*.kz" --include="*.k"

**Bring something that is not already there.** A second transform that rewrites an invocation
into a comment teaches nobody anything. Diverge on *what kind of work* the transform does —
does it read the program, synthesize declarations, enforce a rule, generate code from a literal,
specialize on a type? The catalog grows in **reach**, not in count.

## ⚖️ VARIANCE IS THE METRIC

Across contestants, **variance is the single most important measure of success.** Two
contestants producing near-identical transforms is a failed round even if both are green. If
your idea feels like the obvious one, it probably is — and someone else is building it right
now. Go sideways.

---

## ⚖️ THE FRICTION REPORT — the actual deliverable

Every time you hand-roll something, you have found a gap. Write `FRICTION.md` beside your test
and sort **every** item into exactly one of two buckets. This sorting is the whole point of the
challenge, and it is the part that cannot be recovered later — once your workaround is written,
it reads like perfectly normal code and the gap it papers over becomes invisible.

**Bucket 1 — LIBRARY.** *I wrote code the compiler already knows how to do, and a function
would have handed it to me.* You scanned `prog.items` to find a declaration by name. You
assembled an `ast.Item` field by field. The compiler has this information; nothing is missing
from the language, only from your reach.

**Bucket 2 — CONTRACT.** *I wrote a CHECK for something I should have been able to DECLARE, so
the compiler enforces it and my code never runs at all.* This is the valuable bucket and the
easy one to misfile.

The worked example, and the reason this challenge is shaped this way: twenty transforms in
`koru_std` each open with the identical runtime assertion —

    if (item.* != .flow) @panic("...: containing item is not a flow - walker dispatch contract broken")

Twenty-one copies of one precondition. The tempting report is *"I wanted an `assertFlow`
helper"* — **bucket 1, and wrong.** A helper deduplicates the check and makes it permanent. If a
transform could *declare* that it applies to flows, beside `keyword` and `pre`, the walker would
never dispatch a non-flow and all twenty-one checks would **stop existing**. That is bucket 2.

The test that separates them: **could the compiler have known this before running my code?** If
yes, it is a contract, not a helper. When genuinely torn, file it in **both** and say why —
an honest double-file is worth more than a confident miss.

---

## Done-gates — self-check ALL of these before you claim finished

Objective, and yours to verify. No contestant is finished until every one passes:

1. **It compiles.** `./zig-out/bin/koruc <your file>` — clean.
2. **It is pinned.** A regression test under `tests/regression/800_CHALLENGES/`, with the
   markers its own shape demands: `MUST_RUN` + `expected.txt` for a transform that produces
   output, or `MUST_ERROR` for one whose *rejection* is the point.
3. **The pin actually pins.** A `MUST_ERROR` must name the diagnostic it expects —
   `expected_error.txt`, or a `CONTAINS` / `ERROR_AT` line in `EXPECT`. The harness rejects a
   negative test that pins nothing, because such a test passes on **any** failure. Do not route
   around this wall; it exists to stop exactly the fake green you would otherwise ship.
4. **It runs green.** `./run_single_test.sh tests/regression/800_CHALLENGES/<your test>`
5. **It is not degenerate.** Empty output where output was the point, a transform that declines
   every site, a test that would pass with the transform deleted — all fail this gate. Delete
   your transform and re-run: if the test still passes, you have pinned nothing.
6. **`FRICTION.md` exists**, with both buckets present (write "none" if a bucket is genuinely
   empty — an absent bucket reads as an unasked question).

**The taste-gate is not yours.** Lars judges whether the transform earns a place in the catalog.
Ship it finished; do not pre-negotiate it.

---

## ⚖️ THE HARD STANCE — a wall is not an invitation

You will hit walls. When you do, there are always two readings and **they are not yours to
choose between**:

- **(A) the toolchain is missing something** — a real gap in the comptime surface.
- **(B) you are holding it wrong** — the surface supports this and you did not find how.

Assume roughly **even odds** and go looking for prior art before you lean: grep the corpus for a
green test doing the adjacent thing. A passing example of the shape is strong evidence it is
**intended-legal**, and that your approach — not the compiler — is what is wrong.

**Never patch around a toolchain gap to make your transform work.** Emitting raw Zig that
sidesteps a missing contract, reaching into emitter internals, hand-mangling a name the compiler
should have spelled — these produce a green test that teaches us a lie. If the wall is real,
**stop, and report it as the finding.** A contestant who ships nothing but a well-grounded
bucket-2 gap has had a better run than one who shipped a working transform built on a hack.

**And never lower a done-gate to pass it.** Changing a test until it goes green, with no
investigation in between, is the one pathology this repo does not forgive.

---

## What survives

The transform and its pin go into the catalog. `FRICTION.md` accumulates across every replay,
and the recurrences across many reports — not any single one — are what will eventually name
Koru's comptime standard library. That is why the sorting matters more than the transform: we
are trying to learn the shape of the missing thing from many independent encounters with it,
rather than guessing at it from the inside.
