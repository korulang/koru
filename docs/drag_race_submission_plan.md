# PrimeKoru — Drag Race Submission Plan

Work document. Goal: submit a `PrimeKoru` entry to
[PlummersSoftwareLLC/Primes](https://github.com/PlummersSoftwareLLC/Primes) (Dave
Plummer's software drag race). Not because the percentages matter — because it
puts Koru in front of eyeballs and under real scrutiny, which improves everything.
We are an exotic language now; the repo welcomes those, and the scrutiny is the
point. Pick this up in a dedicated session.

## Honest current state (measured 2026-06-27, this machine, arm64, single thread, 1M)

The thing that makes us fast is REAL and honest: `std/field:mark-multiples` is a
`[transform]` — **Koru's compiler generates the per-stride unrolled SIMD marker**
(residue-class-mod-p → baked immediate masks → fn-ptr LUT dispatch). Same machinery
as regex→DFA. The generated marking is at/above hand-tuned Zig.

But measure FAITHFUL-to-FAITHFUL (each pass re-allocates the sieve, per the rules):

| faithful=yes | p/s |
|---|---|
| Zig sol3 (PrimeZig) | ~17,000 |
| **Koru (new/free per pass)** | **~14,000** (noisy; one round dropped to ~4,300) |
| C++ sol5 (PrimeCPP) | ~13,700 |

- **Faithfully, Koru ≈ C++ sol5, and is behind Zig sol3.** Do NOT claim "beats sol3."
- The `clear`-reuse sieve hits ~17,400 (beats sol3) but that is **`faithful=no`**
  (reuses the buffer). Legit as a `faithful=no` entry, but must be compared only to
  other `faithful=no` entries and labeled honestly.
- **The faithful gap is ALLOCATION, not marking.** Per-pass `new`/`free` through the
  safety GPA is expensive and page-faults each pass (hence the noise + the 4,300
  outlier). The marking, measured with allocation out of the picture, is champion-class.

### Implication for what we submit
Two honest options, decide in the submission session:
1. **`faithful=no` entry now** — the `clear`-reuse sieve (~17,400). Honest, beats the
   `faithful=no` field, ships today. Clearly labeled `faithful=no`.
2. **Competitive `faithful=yes` entry** — requires cheaper per-pass allocation first
   (arena/pool, or the escape-driven local allocation in the `std/field` "castles"
   vision). That lifts faithful toward the ~17k marking ceiling. More work, bigger flex.
Recommendation: ship (1) honestly for eyeballs; pursue (2) as the real prize. Possibly
submit BOTH variants (the Zig/C++ entries ship multiple), one per faithfulness class.

## Submission requirements (from the repo's CONTRIBUTING.md — read in full before submitting)

- **Sieve of Eratosthenes**, primes ≤ 1,000,000, benchmarked code returns the bit
  array / prime list. Run ≥5s, stop ASAP after. BSD-3 (or more permissive) license.
- **Output line to stdout**, exactly:
  `koru;<passes>;<seconds>;<threads>;algorithm=base,faithful=<yes|no>,bits=1`
  (en_US decimal, `.` separator). Any aux output → stderr.
- **New language dir**: `PrimeKoru/solution_1/` on the **`drag-race`** branch. README
  (description, run instructions, output). PR targets `drag-race` (not main).
- **Dockerfile that builds and runs from SOURCE.** Critical rule:
  > "If a solution depends on an external compiler/toolchain that is not a standard
  > distribution package, that toolchain must be built from source within the
  > Dockerfile. Pre-built opaque binaries fetched at build time are not acceptable."
  So the Dockerfile must build `koruc` (Zig) from source, then compile the Koru sieve.
  amd64 + arm64 if possible. hadolint-clean.
- **Honest-representation rule (READ THIS):** the benchmark logic — sieve, timing
  loop, pass counting — must be in the entry's language. Our sieve, find loop, and
  (eventually) timing loop are Koru; `mark-multiples` is a Koru stdlib `[transform]`
  that *generates* the marker — stdlib lowering through Zig is the same category as
  any language's stdlib (Rust intrinsics, C builtins). The README must state this
  plainly and accurately. Maintainers exercise discretion; don't overclaim.

## Open blockers / TODO (for the submission session)

1. **5-second self-timed harness in Koru — THE GATE, partially investigated 2026-06-27.**
   Findings (verified, not assumed):
   - Koru has NO `while`/condition loop. `for(0..N)` is counted-only (N may be a
     runtime expr, but you must know the count up front — can't loop on time).
   - Koru DOES have a conditional back-edge loop: the **label-fold** (`name = #L head(...)`
     / `@L(...)`), green in day-4 (`810_041`) and day-20 (`810_201`). The loop CONDITION
     lives inside the HEAD EVENT (it returns a continue-branch vs an exit-branch); the
     back-edge `@L(...)` must be a DIRECT branch arm (not nested under an `if`); and ALL
     threaded state — including constants like a deadline — must flow through the
     continue-branch's payload and be re-passed by `@L`.
   - A self-timed loop is therefore expressible IN PRINCIPLE: a flow-defined head event
     `tick(deadline, passes)` that calls `std/time:now` and produces `| live {deadline,
     passes}` (continue) vs `| expired passes` (exit). The field is `new`/`sieve`/`free`
     INSIDE the live branch (local per pass — avoids the KORU030 owned-resource-threading
     gap, since only the scalar count crosses the back-edge).
   - **BLOCKER (not yet resolved):** that flow parses and gets deep into emit, then fails
     with `struct 'koru_std' has no member named 'koru_control'` — the `if` inside a
     flow-event-body-used-as-a-loop-head emits a `koru_std.koru_control.if_event` reference
     that the dependency pass doesn't include. Plain `if` in a top-level flow works fine
     (the sieve uses it); `if` in day-20's flow-event-head works too — so this is a
     specific emit/dependency interaction, NOT impossible. Root-causing it is THE first
     real build for an honest harness. (A `|zig`-proc time event as the loop head instead
     hits "Unknown event referenced" — a different label-fold emit gap; the flow-event
     head got further, so pursue that.)
   - **Consequence, stated plainly:** until this loop compiles, we CANNOT run the official
     self-timed protocol, so we do NOT have an honest official drag-race number — only
     `/usr/bin/time`-over-fixed-passes approximations. No "we beat/match X" claim is
     legitimate until the real harness produces a real number.
2. **Emit the exact output format line** from Koru (string formatting of passes/time;
   `std/io` + `std/fmt`). One-shot mode (`-1`) optional.
3. **Dockerfile**: build Zig from source (or pinned source build), build `koruc`
   (metacircular: `zig build`), compile the sieve, run. Test the full Docker build.
4. **Faithfulness decision** (see above) + the allocation lever if going for a
   competitive faithful entry.
5. **Validation**: the harness must validate 78498 (π(1,000,000)) — already proven by
   `tests/regression/.../2109_prime_sieve_generated` (MUST_RUN, 78498).
6. **README** with honest numbers, the "compiler generates the marker" story, and the
   faithful/unfaithful labeling.

## Artifacts that already exist (this session)

- `koru_std/field.kz` — `std/field` bitset + `mark-multiples` `[transform]` (generated
  marker, fn-ptr LUT dispatch). Committed: `2c748da2`, `1205d375`.
- `tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2109_prime_sieve_generated/`
  — the green pin (78498).
- Scratch (in `/tmp/koru_bench`, not committed): `mmfair.k` (faithful), `mmreuse.k`
  (unfaithful/clear), `gen_harness.zig` (codegen prototype), `ceil_probe.zig`,
  `sparse_spec_probe.zig` (the falsified sparse experiment), the built PrimeZig sol3 /
  PrimeCPP sol5 reference binaries (Zig 0.8.0 at `/tmp/zig-macos-aarch64-0.8.0`).
- The blog post `the-wheel-was-the-wrong-optimum` (korulang_org) tells the journey.

## The honest framing (so we don't look like idiots — which is the productive place to be)

State exactly: high-level Koru language; the sieve/find/timing are Koru; the marking is
a Koru stdlib transform that the COMPILER generates (not hand-written per-program Zig);
faithfully we currently tie C++ and trail the Zig champion because per-pass allocation
is our bottleneck, not marking; the marking itself is at/above hand-tuned Zig. Label
faithful vs unfaithful precisely. Let the scrutiny improve it.
