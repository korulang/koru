---
type: belief
id: frag-a-compile-only-test-cannot-see-the-artifact
provenance: cross-compilation stopped working somewhere between 2026-02-13 and 2026-05-04; the only two tests covering std/build:config were COMPILE_ONLY, so nothing in 1,565 tests could move, and three separate artifacts recorded the silence as a compiler gap
ts: 2026-08-05
---

# A COMPILE_ONLY test asserts acceptance, not output — a property living only in the produced artifact is unwitnessed by construction (belief)

A test marker is a choice about **what may be observed**. `MUST_RUN` observes
behaviour. `MUST_ERROR` observes a diagnostic. `COMPILE_ONLY` observes exactly
one bit: the compiler exited zero. Everything the compiler *produced* is outside
its field of view — not weakly covered, **invisible**.

So any compiler behaviour whose only evidence is a property of the emitted
artifact has no wall anywhere in the corpus, however large the corpus is. Not
because someone forgot to write the pin, but because the marker they reached for
cannot express the assertion.

`std/build:config { "target": ... }` is the clean instance. Two tests covered it,
`310_057` and `310_058`, both `COMPILE_ONLY`, and both were *correct*: they pin
that the annotation survives quote-escaping into the emitted Zig. Neither reads
the architecture of `a.out`, because their marker cannot. When target threading
stopped reaching the backend, both stayed green.

The absence then propagated as a positive claim, three times, each reader
inheriting the last:

- **2026-02-13** — the blog "A 14KB Docker Image That Serves HTTP" ships a real
  `x86_64-linux-musl` binary cross-compiled from macOS. True when written.
- **2026-05-04** — `embedded_blinky/results.md` records the koru row as `native`,
  "no cross-compile threading for that toolchain yet."
- **2026-06-01** — `koru-os/FINDINGS.md` reproduces it in nine lines, calls it a
  real toolchain gap, and stops rather than touch the compiler.

None of it was a compiler gap. Those probes wrote `std.build:config` with the
dot namespace retired by `5f41236f`; the slash spelling cross-compiles on main,
first try. The corpus could not distinguish "cross-compiles" from "silently
builds native", so a syntax typo wore a two-month compiler blocker's clothes, a
published claim quietly became unreproducible, and the board never flickered.

## What follows

- **Ask what the marker can see before trusting the coverage.** "There are tests
  for it" is not the question. "Could any of them have gone red for *this*
  property" is. A property of the artifact needs a test that reads the artifact.
- **A green COMPILE_ONLY test is compatible with the feature being entirely
  dead.** It is evidence about the front end and silence about everything after.
- **The cheap fix is to make the program assert its own artifact at comptime.**
  The harness has no marker for "check the target architecture", and it does not
  need one: a `@compileError` guarded on `@import("builtin").cpu.arch` inside a
  *fired* tor turns an unobservable artifact property into a compile failure,
  which `COMPILE_ONLY` *can* see. The assertion has to sit in a tor something
  actually invokes — an unfired `~pub tor main` emits a `main()` holding only the
  flow prologue and epilogue, so its body is never analysed and the wall does not
  exist. That is `310_119`, verified in both directions: with the target it
  builds an x86-64 ELF and exits 0; without it, `emitted code compiled for
  aarch64, expected x86_64`, exit 1.
- **Suspect this wherever the compiler's output is the product.** Target,
  optimisation mode, stripping, section layout, linked libraries, emitted symbol
  names — all of them live past the boundary `COMPILE_ONLY` draws.

## Open

- How many other artifact-level properties are covered only by `COMPILE_ONLY`?
  There are 26 such tests. Nobody has audited what each of them believes it is
  guarding versus what it can actually observe.
- The comptime-self-assertion trick is reusable but hand-rolled per property. If
  it recurs, it wants to be a marker the harness understands rather than a
  pattern each author rediscovers.
