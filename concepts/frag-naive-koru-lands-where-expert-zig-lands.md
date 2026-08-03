---
type: belief
id: frag-naive-koru-lands-where-expert-zig-lands
provenance: boids, 2026-08-03. Written when Koru ran a borrowed DOTS workload at ~99ms against hand-written striped Zig's 217ms; CORRECTED the same evening after Lars asked what "no expression-local binding" meant if `capture` exists, and the short version measured identical
ts: 2026-08-03
---

# Naive Koru landed where expert Zig lands — and every explanation I gave for WHY was wrong (belief)

A borrowed workload — Unity DOTS' BoidSystem, their constants, a bit-identical
checksum across four implementations — ran ~99ms in Koru against 217ms for
hand-written striped Zig. That measurement stands and is the durable part.

Three separate explanations for it were offered and each was refuted by a
measurement:

- **"Our static data model is why."** Refuted: giving the Zig baseline Koru's
  exact fixed-extent globals, alone, changed nothing (221ms → 221ms).
- **"Koru has no expression-local binding, so it inlines per component, and that
  is what produces the vectorisable shape — the verbosity IS the optimisation."**
  Refuted twice over. Koru *has* expression-locals: `capture` slots, and pure
  subflows with an arrow return (`tor f {…} -> f32`, then `f(…): c` binds `c`,
  the shape 690_131 already used). And when the steering was rewritten with both
  — 12,983 characters down to 3,497, a 4x reduction — it ran at the SAME speed
  and stayed vectorised.

  The distinction that survives, and it is not the same claim: the per-component
  SELECT SHAPE does matter, priced independently at 1.7x inside already-vectorised
  code (93.2ms selects against 155.8ms for an integer-mask formulation, all else
  equal). But that shape is a property of the emitted code, not of how much source
  you wrote — the 4x shorter version produces it too, because a helper returning
  a scalar per component still yields three selects. Shape is load-bearing;
  verbosity was incidental to it, and I conflated them.
- **"rustc cannot vectorise this body."** Refuted: with panic edges removed and
  the vector width forced, rustc produces a 4-wide loop that beats Koru.

## What is actually true

Three bars, and a body must clear all of them:

1. **Legality.** Bounds-check panic edges are early exits; LLVM refuses outright
   ("Cannot vectorize early exit loop with more than one early exit").
2. **Aliasing.** With heap columns the runtime alias checks make widening
   unprofitable — measured, nothing in the body helps while they are present.
3. **Cost model.** Even legal and alias-free, the vectoriser weighs the
   lane-insert gathers and can decline; on the Zig pipeline either body
   flattening tips it, on rustc it declines until forced.

**Koru clears all three without anyone deciding to** — its trap edge is waived
at the declaration, its columns are module-level arrays at static addresses, and
its emitted per-component selects are the shape the cost model says yes to. That
is the whole claim, and it is enough.

## The real language constraint, stated correctly

Not "no expression-local binding". It is **KORU104: calls are not expressions.**
`f(g(x))` is refused; a helper's result is bound in the chain and then spent.
That is a real constraint on math-heavy code — it turns nested composition into
a sequence of named steps — and it is a *shape* cost, not a speed cost. Measured:
none.

## The pattern that produced four wrong claims in one day

Every one of them has the same structure: **I authored a program, then reasoned
about the language from the shape I had authored.** The inlined steering was my
generator's output, not Koru's requirement; I read my own output back as
evidence about the language and built a causal story on it. The corpus contained
the counter-example each time — `capture` in a dozen nesting-sweep tests,
arrow-return subflows in 690_131 — and I never looked, because the code in front
of me really did have the property I was describing.

The check is one grep and I skipped it four times. Worth more than the
performance finding: **before attributing a program's shape to the language,
search the corpus for the construct you believe is missing.**

## Open

- Whether the AoS-vs-SoA grid layout finding (measured 1.66x on the scatter
  phase, cross-corroborated in two languages) is worth a std/grid cell record.
  That is the largest unclaimed item on this workload.
- Why rustc declines where Zig accepts, same LLVM, all three bars cleared.
  Target-CPU was eliminated as the cause. A genuine open compiler question.
