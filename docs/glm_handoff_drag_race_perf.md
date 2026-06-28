# GLM 5.2 Handoff — PrimeKoru drag race: pin (and close) the last ~17%

**You are picking this up cold in a fresh session.** Everything you need is below.
Read it fully before touching anything — a previous session already spent ~30
diagnostic steps grounding the facts here; don't redo that, build on it.

Report back a markdown document (structure at the bottom) that the maintainer and
the prior agent will read together.

---

## Mission

Koru is a high-level language whose **compiler generates SIMD compute kernels**
(`std/field:mark-multiples` is a `[transform]` — the programmer writes naive
"mark the multiples," the compiler emits the specialized vectorized marker; same
machinery as regex→DFA). It has a prime-sieve entry for Dave Plummer's drag race
(`PlummersSoftwareLLC/Primes`).

**On a native x86 Xeon 8168, single-thread, faithful=yes, algorithm=base, bits=1,
official 5s self-timed protocol, all validating π(1e6)=78498:**

| Entry | passes/sec | note |
|---|---|---|
| sol3 `51` — Zig, hand-unrolled (deLUT/spLUT) | ~7,990 | champion |
| **koru** | **~6,650** | compiler-generated marker |
| sol5 — optimized C++ | ~5,360 | |

koru **beats optimized C++** and lands **~17% behind the hand-tuned Zig champion**.
Your job: **find where that 17% goes, and close as much of it as you honestly can**
— while keeping the entry faithful=yes and the marker compiler-generated (do NOT
hand-tune the `.k`; improvements go in the compiler/stdlib codegen).

---

## What is already SHOWN (grounded in disassembly + emitted Zig — do not re-litigate)

1. **koru's marking technique is at PARITY with the champion.** `mark-multiples`
   generates BOTH:
   - **DENSE** (stride < 64): AVX-512 periodic-mask whole-buffer marking. Disasm
     shows `vorps (%r9),%zmm0,%zmm3` — 512-bit / 8×u64, the same width as sol3's
     `@Vector(8,u64)`. One specialized fn per stride (`__mm_23_12_3` … `_63`).
   - **SPARSE** (stride ≥ 64): jump-to-multiples (`__mm_sparse_23_12`, body
     `… byteIdx += stride; bi += step8;`) — it does NOT stream the whole buffer.
   - **Crossover at exactly 64** — identical to sol3's `isDense: factor < 64`.
   So the dLUT *and* spLUT are already compiler-generated. This is not the gap.
2. **The per-pass clear is fast and NOT the bottleneck.** It's `@memset(buf,0)`;
   micro-benchmarked at ~1µs for the 62KB buffer, **identical** for compiler_rt and
   glibc (`-lc`). Linking libc did **not** change the full sieve number. Ruled out.

## What is RULED OUT
- The marking algorithm/technique (dense+sparse, AVX-512, crossover) — parity.
- memset speed (libc made no difference).

## The OPEN question (this is your target)

Where does the ~17% per-pass gap go? Phase-isolation variants (built by editing
`faithful.k`) gave, on the Xeon 8168:
- **full faithful**: ~6,650 p/s (~150 µs/pass)
- **alloc+clear only** (sieve for-loop removed): ~17,800 p/s (~56 µs/pass)
- **bare loop** (no alloc, no sieve): ~39M p/s (~0.026 µs/pass — negligible)

⟹ sieve/marking ≈ 94 µs, alloc-path ≈ 56 µs. **The 56 µs is the mystery: it is NOT
the memset (~1µs).** Cause unknown — that decomposition may also be unreliable
(removing the for-loop can shift optimizer/cache behavior). Candidate hypotheses:
- per-pass 62KB stack-frame setup / probing / TLB effects (escape-driven stack alloc),
- find strategy: koru iterates ALL odd candidates `for(1..500){ test(f,i); if prime mark }`
  (~330 wasted `test()` on composites) whereas sol3 uses `findNextFactor` to skip
  straight to primes — different inner-loop structure,
- sparse-marker micro-efficiency vs sol3's per-residue comptime-unrolled `fillOneChunk` + fn-ptr LUT,
- cache residency of the 62KB buffer across the ~167 marker calls per pass.

**The prior session could not attribute this** because the box's profilers are broken
(see Blockers). Your first job is to get a real profile.

---

## Environment & exact reproduction

- **Repo:** `github.com/korulang/koru`, branch `main`, **at or after commit `d0ec76e6`**
  (that commit fixes two x86-Linux-only koruc bugs — an aggregate-init miscompile and a
  dual-`std`/duplicate-`os.environ` segfault — without which the x86 build won't even run).
- **Build koruc:** `zig build` (Zig **0.15.2**). Self-contained, no deps.
- **The entry:** `benchmarks/workloads/prime_sieve_drag_race/koru/faithful.k`.
  Compile in a scratch dir (**koruc clobbers CWD**): `<repo>/zig-out/bin/koruc faithful.k`
  → emits `./a.out` (built `-OReleaseFast`, native target). Run `./a.out` →
  `validated primes: 78498` then `koru;<passes>;<sec>;1;algorithm=base,faithful=yes,bits=1`.
- **Dockerfile (builds koruc from source, validates 78498):**
  `benchmarks/workloads/prime_sieve_drag_race/Dockerfile`.
- **Rivals** (`PlummersSoftwareLLC/Primes`, branch `drag-race`):
  - sol5 = `PrimeCPP/solution_5`; run single-thread: `docker run --rm sol5 dummy -t 1 -l 1000000`.
  - sol3 = `PrimeZig/solution_3`; **bump base image `debian:buster-slim` → `debian:bookworm-slim`**
    to build (buster apt repos are EOL/404). The comparable line in its output is
    `51-…zig-single-bitSieve-unrolled-…deLUT-spLUT-find-u32` (1 thread, faithful=yes,
    algorithm=base, bits=1). Its technique lives in `src/unrolled.zig` (dense/sparse
    `isDense`, allocator via libc `calloc` in `src/alloc.zig`).

## Profiling BLOCKERS the prior session hit (bring a box that avoids these)
- **`perf` failed** — cloud-kernel mismatch (`perf record` couldn't load on the DO droplet's
  kernel). Use **bare metal**, or a distro/kernel where `perf` works, or install matching
  `linux-tools-$(uname -r)`.
- **`callgrind` hit `Illegal instruction`** — the native ReleaseFast build emits **AVX-512**
  that valgrind 3.18.1 can't emulate. Workarounds: build the output for a **baseline / no-AVX-512
  target** for callgrind (accept the profile is skewed away from the SIMD marker), or just use a
  perf-capable kernel.

## Suggested plan
1. Provision an **x86 Linux box with working `perf`** (bare metal preferred). The prior session
   used a DigitalOcean **c-4** dedicated-CPU droplet (Xeon 8168) via `doctl`. (SSH key for the
   maintainer's setup is local at `~/.ssh/koru_bench` if reused; otherwise make your own.)
2. Build koru's `faithful.k` and sol3 variant 51 on it.
3. `perf record -g ./a.out && perf report` → real hot-function breakdown. Settle the ~56µs
   alloc-path mystery and the marking cost. Do the same for sol3.
4. Diff koru vs sol3 function-level. **Attribute the ~17%.**
5. If a lever emerges, prototype a fix in the right layer — `koru_std/field.kz` (the
   `mark-multiples` transform / the field alloc+clear path) and/or `src/` codegen — rebuild,
   re-measure. **Keep faithful=yes; keep the marker compiler-generated.**

## Report back — produce a markdown document with:
1. **perf breakdown** (koru vs sol3, function-level, on one box).
2. **Attributed root cause** of the ~17% (and of the ~56µs alloc-path number).
3. **Concrete fix recommendation** (which layer, what change).
4. If implemented: **before/after SHOWN numbers** — single-thread, faithful=yes, base, bits=1,
   same box, validating 78498.

## Discipline (non-negotiable — this is a public, reputational artifact)
- Every number carries **SHOWN / MEASURED-narrow / UNVERIFIED**. No "beats/matches X" unless
  **SHOWN on the same box, same thread count, same faithfulness class, same protocol**.
- faithful=yes compares ONLY to faithful=yes. The official ranking runs on Dave's machines —
  our box numbers are for understanding, not official standings.
- Note: koru's faithful=yes leans on the argument that **automatic stack-placement of the
  per-pass `new` is still faithful** (the source allocates anew each pass; the compiler
  optimizes placement — like Go/Java escape analysis). If you change the alloc path, preserve
  that property or flag it.
