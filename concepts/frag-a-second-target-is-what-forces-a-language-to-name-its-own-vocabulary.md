---
type: belief
id: frag-a-second-target-is-what-forces-a-language-to-name-its-own-vocabulary
provenance: the JS port of std/store's query guard and std/kernel's op body — three symptoms that turned out to be one cause, and a vocabulary that was already written on exactly one side
ts: 2026-08-07
---

# A single-target language never has to say what its operations are; the second target is what makes it (belief)

Koru writes `@sqrt(x)`, `@mod(a, b)`, `@as(i64, v)` in ordinary expression
positions. For as long as Zig was the only target, nobody had to decide whether
those were **Koru operations** or **Zig builtins leaking through a hole**,
because the question had no consequence: Zig accepts them, so passing them
through is indistinguishable from understanding them. The Zig emitter passes
essentially every expression through verbatim, and that is not laziness — it is
the correct implementation of "the host spelling is the spelling" — but it is
not COMPLETE, and the counterexample was measured on 2026-08-07: `==` on two
strings. Koru's `==` on strings is value equality — the comptime fold
(`comptime_eval.zig` folds it with `mem.eql`), the interpreter, and the JS
target all already agreed — and Zig has NO verbatim spelling for that:
`[]const u8 == []const u8` is a compile error. Pass-through was not
"understanding by coincidence" there; it was a raw Stage-D leak ("cannot
compare strings with ==") refusing a program three other organs of the same
compiler considered meaningful.

JavaScript cannot do that. `@sqrt` is a syntax error, `and` is a syntax error,
`x << 32` is a no-op rather than an error. So the JS emitter had to enumerate the
operations it understood and **refuse the rest** — and an enumeration plus a
refusal is what a definition IS. The vocabulary of Koru's `@`-operations was
therefore written, in full, on the JS side and nowhere else, as a consequence of
porting rather than as an act of language design.

**The general claim:** a language with one backend cannot discover its own
surface, because every question it might ask is answered by default. The second
backend is not merely a port — it is the instrument that makes the surface
observable, and the first place its definition appears will be the side that
could not pass anything through.

## The three symptoms were one bug, and none of them was a missing feature

A `std/store` query guard reached `node` as `hp > 40 and kind == 1`. A
`std/kernel` op body reached it as `@sqrt(dsq)`. Both read as gaps in the
language. Neither was.

`js_emitter` had mapped `and` to `&&` and `@sqrt` to `Math.sqrt` for months. The
lowering was reachable **only from text the emitter itself wrote**, and every
other route an expression takes to a host — a transform splicing a guard into a
proc body it assembles, a kernel op body pasted into a generated loop — carried
it past the pass untouched. Three symptoms, one cause: *text that never reaches
the one thing that knows how to lower it.*

The corrective worth keeping: **`@sqrt` was on a list of things needing a design
ruling, and it never needed one.** A missing lowering and an unreachable lowering
present identically at the failure site, and the difference is invisible unless
someone greps the emitter for the operation's name. Before booking a symptom as a
language gap, check whether the answer already exists somewhere it cannot be
called from.

## Where the definition lives now, and what is deliberately still open

The pass is `codegen_utils.lowerKoruExpr`; the vocabulary is `lowerBuiltin`
beneath it. `js_emitter` is now one of its callers rather than its owner, and so
are `std/store` (guards) and `std/kernel` (op bodies).

**RULED (Lars, 2026-08-07): the Zig spelling stays the Koru spelling for now, and
the exact shape of the vocabulary is deliberately not settled.** The reasoning is
the load-bearing part: the shape is cheap to change once there is *one home* for
it, and expensive to argue about while there are two. Getting something in place
that has a relationship to a vocabulary beats getting the vocabulary right.

So the `.zig` arm is the identity **for the vocabulary** — with one semantic
carve-out it now carries (2026-08-07): a literal-grounded string `==`/`!=`
rewrites to `@import("std").mem.eql(u8, …)`, because that operator's Koru
meaning has no verbatim Zig spelling at all (see above). That rewrite is not
the wall this section defers — it refuses nothing; it makes programs run that
every other organ already accepted. The distinction worth keeping: *identity
is a sound default where the host shares the semantics, and a silent leak
where it does not* — "comparison is shared" was true of every comparison
except the one on strings. What the ruling still defers, stated plainly
because the whole point of writing it down is that it not go invisible: **the
vocabulary is enforced on JS and absent on Zig.** A `.k` naming an `@foo` nobody modelled is
accepted by one target and refused by the other, so the table can drift into
"whatever JS happened to need" rather than "what Koru means" — which is
[[frag-a-wall-guards-one-direction-of-a-symmetry]] with the guarded direction
being, as always, the one that already hurt.

The drift is the *status quo*, not something this change introduced, and one home
makes it a one-word fix instead of a re-plumb. But the fix is a WALL: growing the
`.zig` arm from identity to table-consulting will refuse programs that compile
today, on purpose. That is a language ruling and it has not been made.

## What would correct this belief

A third target close enough to Zig that it, too, can pass expressions through
unmodified — which would show that "the second target forces the definition" was
really "an unlike-enough target forces the definition," and that likeness rather
than count is the variable. The census makes that testable rather than
rhetorical: of 750 pure `.k` files only 62 use any Zig-only expression form, and
`orelse`, `catch`, `.?`, `try` and `|err|` appear zero times. The surface is
already far closer to Koru than to Zig, so a third host may find much less to
refuse than JavaScript did.
