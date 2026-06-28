# PrimeKoru — Performance Squeeze Brief (for a commissioned fresh-eyes run)

**Mission.** Squeeze more passes/sec out of the Koru prime-sieve drag-race entry.
Fan out 2–3 sub-agents with fresh eyes. The toolchain is the product — every
optimization must go THROUGH Koru / `std/field` / the compiler, never around it
(no hand-written Zig sieve, no bypass). If a gap blocks an optimization, the gap
becomes the work; fix it in the compiler/stdlib, don't route around it.

> Status discipline (non-negotiable, this is a competitive/public artifact):
> every number carries SHOWN / MEASURED-narrow / UNVERIFIED. No "beats/matches
> X" claim unless SHOWN under the other entry's exact rules + protocol. The
> faithfulness category is part of "the rules" — never compare across it. When
> unsure, sandbag.

---

## What this is

A Sieve of Eratosthenes (primes ≤ 1,000,000) for Dave Plummer's software drag
race (`PlummersSoftwareLLC/Primes`). The flex that is REAL and honest: the
marking is **compiler-generated**. `std/field:mark-multiples` is a `[transform]`
— for each dense prime stride the Koru compiler emits a fully-unrolled,
residue-class-mod-p SIMD marker with per-word masks baked as immediates and
fn-ptr-LUT dispatch (same machinery as regex→DFA, kernel→SIMD). The program just
says "mark the multiples"; the compiler writes the specialized marker.

The sieve, the find loop, the timing loop, and the pass count are all Koru. The
only Zig is the clock read (`std/time:now`) — that is how Koru does ALL effects
(Zig is Koru's effect substrate), and it is not disqualifying.

## Current honest numbers (SHOWN this session, arm64 native macOS, 1M, 1 thread, official self-timed protocol)

| variant | tag | passes/sec | how |
|---|---|---|---|
| faithful sieve | `faithful=yes` | **~13,200** (12.7k–13.4k over 5 runs) | `std/field:new` + `free` every pass |
| reuse sieve    | `faithful=no`  | **~16,000** warm (run 1 cold ~12.3k) | `std/field:clear` + reuse one buffer |

Both validate **78,498** primes (π(1,000,000)). ✅

**The bottleneck is measured, not guessed:** the faithful↔reuse gap (~13.2k vs
~16k) IS the per-pass allocation cost. Marking is not the bottleneck.

## The sharp target

- **Faithful entry (the real prize): make per-pass allocation cheaper.** The
  rules (see below) require re-creating the sieve each pass, so we cannot reuse
  the buffer and stay faithful — but we CAN make the allocation itself cheap:
  arena/pool reset per pass, or the escape-driven local allocation in the
  `std/field` "castles" vision. Lifting faithful toward the ~16k reuse ceiling is
  the biggest win. Per-pass `new`/`free` currently goes through the safety GPA and
  page-faults each pass.
- **Marking micro-opts:** the generated marker is already at/above hand-tuned Zig
  (MEASURED prior session, NOT re-SHOWN — re-verify before claiming). Lower
  priority; the gap is allocation.
- **`faithful=no` entry:** reuse already works (~16k). Honest, ships, but compete
  it only against other `faithful=no` entries.

## First-class task: stand up the 3-way Linux bench (sol3 + sol5 + Koru)

You cannot tell whether an optimization closed the gap without the rivals running
*beside* you on the same host. So part of this mission is the measurement rig:

1. `docker build` the rival images from their own Dockerfiles
   (`PrimeZig/solution_3`, `PrimeCPP/solution_5`) and a `PrimeKoru` image (build
   koruc from source — the rodata fix `46458d9d` makes this work on Linux).
2. Run all three on the SAME Linux host under the official 5s self-timed protocol
   (or drive the official `/tmp/Primes/tools/` orchestrator, which does exactly
   this). Compare `faithful=yes` to `faithful=yes` ONLY.
3. **Report ratios, not just absolutes, and stamp the environment.** If the host
   is amd64 **emulation on Apple Silicon**, the tax hits SIMD-heavy code (our
   marking AND the NEON-tuned rivals) unevenly → results are **MEASURED-narrow,
   ratios indicative**, NEVER a flat "we beat/tie X". A definitive number needs a
   real x86 Linux host or the official CI. Say which environment produced every
   number.

This rig is what lets every optimization below be judged honestly.

## Dead ends — do NOT re-spend time here (prior sessions)

- **mod-30030 wheel (`2107`)** — elegant, does ~19% of the work, but scatters →
  a vectorization dead-end. Slower in practice than the dense odds+stepMask path.
  (MEASURED prior; the blog post `the-wheel-was-the-wrong-optimum` tells the story.)
- **Bit-packing density tricks** — size-dependent: slower at 1M, faster at 10M.
  The drag race is fixed at 1M.

## Where everything lives

- **`std/field`**: `koru_std/field.kz` — bitset + `mark-multiples` `[transform]`
  (generated marker, fn-ptr LUT), `new`/`free`/`clear`/`test`/`count-zeros`/`strike`.
- **Pins (committed, deterministic, in the suite)** under
  `tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/`:
  - `2109_prime_sieve_generated` — single-pass generated-marker sieve (correctness).
  - `2111_prime_sieve_timed_loop` — pure-Koru `#L`/`@L` timed-loop shape (faithful).
  - (reuse-loop pin — `faithful=no` capability — TODO this session.)
- **Runnable timed entries**: TODO — commit the official-protocol `.k` files into
  the repo (currently scratch in `/tmp/koru_bench`: `prime_measured.k` faithful,
  `prime_reuse.k` reuse). A fresh session cannot run what is only in `/tmp`.
- **Reference rivals** (UNVERIFIED here — numbers below are macOS/prior session,
  NEVER run on Linux or under our protocol; do not state any comparison until they
  are rebuilt + run beside us under the same protocol): Zig PrimeZig sol3 (~17k
  faithful, claimed), C++ PrimeCPP sol5 (~13.7k faithful, claimed). The Primes
  repo clone was at `/tmp/Primes`. **Both rivals ship their own `Dockerfile`** —
  `PrimeZig/solution_3/Dockerfile`, `PrimeCPP/solution_5/Dockerfile` — because the
  drag race requires build-from-source containers. The repo also ships the official
  benchmark orchestrator at `/tmp/Primes/tools/` (TypeScript). So getting the rivals
  on Linux is `docker build` + `docker run` their own images, not a port.

## The rules that constrain optimization (verbatim, `Primes/CONTRIBUTING.md`)

- **Faithful** (`faithful=yes`) requires: no external deps for the sieve; a class/
  struct holding full sieve state, **re-created from scratch each iteration**; the
  buffer allocated dynamically at runtime, sized to the sieve. Reusing/clearing one
  buffer across passes = `faithful=no`.
- **Labels must be accurate** — wrong `algorithm`/`faithful`/`bits` tags are grounds
  for rejection. We use `algorithm=base` (odds-only is canonical "base"), `bits=1`
  (one bit per flag), `faithful=yes|no` per the above.
- Output line, exactly: `koru;<passes>;<seconds>;<threads>;algorithm=base,faithful=<yes|no>,bits=1`
- Run ≥5s, stop ASAP after; aux output → stderr.

## How to build/run (this machine)

```
zig build                                   # build koruc
cd <scratch dir>                            # koruc clobbers CWD — never run in repo root
<repo>/zig-out/bin/koruc prime_measured.k   # compile a timed entry → ./a.out
./a.out                                      # prints validation + official line
```

For a Linux from-source build (submission needs this): the rodata-clone fix
(`46458d9d`) makes koruc build+run from source on Linux. Persistent dev container
`koru-linux-dev` existed prior session.
