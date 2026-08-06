---
type: belief
id: frag-js-fast-paths-drop-what-their-fixtures-never-had
provenance: W2_runtime host-fixture wave — three separate JS-emitter defects, all in code paths written against the 140_01x pump fixtures, all invisible until a fixture carried a shape those fixtures lacked
ts: 2026-08-06
---

# The JS emitter's fast paths are silent about the shapes their fixtures never had

The JavaScript target's two optimisation paths — the void-effect inline
splice and the omitted-arm handling — were both written against the
`140_010`/`140_011`/`140_012` pump fixtures and validated by them. Those
fixtures share a shape: an event with void effect arms, **every arm
handled**, and **no terminal branch**. Inside that shape both paths are
correct, and the corpus said so.

Step one inch outside it and they do not error — they answer wrongly.

- A producer that declares `| done …` alongside its void effects ends its
  body with `return { tag: "done", … }`. The inline splice puts that
  `return` in the FLOW function, so the flow abandons itself and nothing
  ever dispatches on the tag. Measured on `400_072`: `each 0`, `each 1`,
  `each 2` printed, `done 3` did not, and any later flow statement would
  have gone the same way. No diagnostic. The fast path had simply never met
  a terminal, because a pump has none.
- An OMITTED OPTIONAL arm — ruled a producer-side no-op in 2026-07-19's
  Option B, pinned by `400_168`/`400_170` — was not modelled on either path.
  The closure path left the alias `const warn = H.warn;` undefined and the
  fire threw `warn is not a function`; the inline path refused to compile at
  all. The ruling is a year of design work that the Zig target honours and
  the JS target had never been asked about, because no pump fixture omits an
  arm.

The belief this leaves us with: **a target's fast path inherits the blind
spots of the fixtures that motivated it, and those blind spots surface as
wrong output rather than as refusal.** The general path — closures,
`.tag` dispatch, `emitTerminalContinuations` — was correct for all three
cases the whole time. What was wrong was the GATE deciding when the general
path could be skipped, and a gate stated in terms of what the optimisation
*likes* (`all_effects_void`) rather than what it *requires* (…and no
terminal to hand back, and every arm accounted for) will keep admitting
shapes it cannot serve.

The corrective is not "add a case." It is that a fast-path gate should be
written as the negation of its preconditions, derived from what the
transform does to the code, and each precondition should name the fixture
that would catch its violation. `terminal_branches == 0` is that, and it is
one token; discovering it cost a fixture printing three of its four lines.

Open question: the Zig emitter has the same textual-splice helper
(`emitter_helpers.zig:3186`) reached through a different gate. Whether it
carries the same hole, or is protected by something upstream that the JS
path lacks, has not been measured — and "the other target has had longer to
accrete cases" is the reason to check rather than the reason to assume.
