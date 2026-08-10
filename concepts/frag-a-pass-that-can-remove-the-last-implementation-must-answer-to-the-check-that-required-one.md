---
type: belief
id: frag-a-pass-that-can-remove-the-last-implementation-must-answer-to-the-check-that-required-one
provenance: surfaced probing whether koruc accepts two implementations of one abstract tor (it refuses, KORU113); the single-implementation control was the thing that turned out to be broken — resolve_abstract_impl renamed the sole claim to `<event>.default` and the emitter filled the hole with a zero value (2026-08-10)
ts: 2026-08-10
---

# A guard placed before a pass that can reopen the hole is not a guard (belief)

An abstract tor is a declared capability with no body. Exactly one thing may be
true of it at the end of compilation: something implements it. `430_005` pins
the refusal — invoke an abstract tor that nothing claims, and the compiler says
so.

That check runs before the pairing pass, and the pairing pass can **take the
implementation away again**. When it does, nothing re-asks the question. The
refusal is not wrong; it is simply looking at an earlier version of the program
than the one that gets emitted.

The specific way the hole reopens is worth stating, because it is a general
shape and not a typo. Pairing means finding *two* things — an optional default
and the implementation that overrides it — with two separate searches. Both
searches are written against the module qualifier. Canonicalization runs first
and **stamps the enclosing module onto an unqualified implementation**, at which
point a same-file implementation and an override are byte-identical to both
predicates. One declaration answers yes to both questions, the pass concludes a
pair exists, and renames the only implementation to `<event>.default`.

**Two searches over one collection can return the same element, and a predicate
pair that was designed to partition will happily double-count.** The fix is
identity, not a better predicate: find the override as a pointer, then exclude
that pointer from the default search. It holds because the two roles are not
symmetric — a `~proc` can never be an override, so a real default still pairs.

The part that makes this worth a belief rather than a bug note is what the
emitter did with the hole. It did not fail. It produced `return .{ .greeted =
"" }` — a fabricated zero standing in for an answer nobody wrote. A program
built on it compiles, exits 0, and does nothing. This is the *no fallbacks*
tenet violated by the compiler itself: the substitute output is indistinguishable
from the real surface working, so nobody goes looking.

**An emitter reaching a tor with no implementation is not in a recoverable
state; the honest move is to refuse there, at the point of emission, where the
program being emitted is the program that will run.** Placing the check earlier
buys nothing if a later pass can invalidate it. See
[[frag-a-check-that-cannot-match-reports-clean]] for the sibling failure, where
the guard is present but structurally unable to fire.

Open: whether the emitter should carry that refusal itself, or whether the
pairing pass should re-run the existing check after mutating. The first is
harder to bypass; the second reuses a diagnostic that already reads well.
