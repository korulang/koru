# PrimeKoru Drag-Race Submission — Adversarial Review

**Verdict: FIX-FIRST**

Two blockers, both honesty issues. The `faithful=yes` argument is defensible but has a real hole. The sieve itself is correct (78,498 primes validated).

---

## Blockers

### B1. "SIMD" / "vectorized" overclaim — unsupported by the code

**Severity: blocker** — this is the kind of "unsupported claim about language capabilities" the rules explicitly call out as grounds for rejection.

The README's central claim is:

> "You write 'cross out the multiples'; the compiler writes the SIMD."

And:

> "emits a specialized, unrolled, **vectorized** native marker"

The Dockerfile comment repeats it: "the compiler GENERATES the SIMD marker."

**What the code actually does** (`koru_std/field.kz:533-553`): the `mark-multiples` transform generates **unrolled scalar** `data[w + c] |= 0xMASK` operations on `u64` words with compile-time-computed masks. There are no SIMD intrinsics, no `@Vector` types, no explicit vectorization in the generated code. The dense path is a straight-line sequence of scalar OR-stores; the sparse path is an 8-way byte scatter.

If the final binary contains SIMD instructions, that's **LLVM's auto-vectorizer** operating on the unrolled scalar pattern — not the Koru compiler "writing SIMD." The Koru compiler writes unrolled scalar code; the backend optimizer may or may not turn it into SIMD.

**Suggested fix:** Replace "SIMD" / "vectorized" with accurate language. Something like: "emits a specialized, fully-unrolled marker with compile-time-baked masks per stride and residue class, dispatched through a function-pointer LUT — a pattern the backend optimizer can auto-vectorize." The unrolled-residue-specialization story is genuinely interesting on its own; the SIMD claim adds nothing but risk.

### B2. Validation line on stdout — clear rule violation

**Severity: blocker** (or high should-fix if the repo's parser is known to tolerate extra stdout lines).

The rules say: "Auxiliary output **should** go to stderr if the language allows." Koru has `std/io:eprintln` (the brief admits this). The `validated primes: 78498` line is on stdout (`faithful.k:34`).

The brief's excuse — "Moving it changes the benchmarked source" — is weak. The validation pass is **already separate** from the timed loop (lines 18–25 vs lines 27–35). Changing `std/io:print.ln` to `std/io:eprintln` in the validation block doesn't touch the timed hot path at all.

**Suggested fix:** Change line 34's first `std/io:print.ln` to `std/io:eprintln` (or whatever Koru's stderr print is). Update the README "Output" section accordingly.

---

## Should-fix

### S1. `faithful=yes` — the comptime-size hole is real

The faithfulness rule requires "sieve size and corresponding prime candidate memory buffer … set/allocated dynamically at runtime." The entry uses `bits: 500000` (a compile-time literal), and the stack-placement optimization **only fires for comptime-literal sizes** (`koru_std/field.kz:165-174` — `bits_is_literal` check). When it fires, the field becomes `var __fld_buf: [7813]u64 = undefined` on the stack — a compile-time-sized stack array, not a runtime allocation.

The JVM comparison is apt but has a key asymmetry: the JVM starts with a **runtime** allocation and optimizes it away via escape analysis. Here, the optimization **requires** the size to be statically known — it can't stack-place a runtime-sized allocation. So the "dynamic at runtime" requirement is never met on the optimized path.

The source semantics (`std/field:new(bits: 500000)` per pass) are faithful. The compiled behavior (stack array, no runtime allocation) is not. Whether a strict maintainer judges source semantics or compiled behavior is the gamble.

**Recommendation:** The argument is **defensible** — submit `faithful=yes`, but have the `faithful=no` variant (reused/cleared buffer) ready as `solution_2`. The README's faithfulness section is honest about the wrinkle, which is good. But strengthen it by explicitly noting that the stack placement requires a comptime size, and that a runtime-sized variant would heap-allocate (and be faithful without question).

### S2. `mark-multiples` framing (§6) — honest, no change needed

The sieve logic (which cells to mark, the strided sweep, the prime guard) is in Koru. The `mark-multiples` transform generates Zig code, but this is a **stdlib compiler transform** — the same category as Rust's `slice::fill` being implemented in LLVM IR, or C's `memset` being a compiler intrinsic. The program is in Koru; the compiler generates native code. This is **not** "calling into another language for the hot part." The framing is fair.

### S3. `KORU_REF=drag-race-v1` tag not yet pushed

The Dockerfile defaults to a tag that doesn't exist. The smoke test used `--build-arg KORU_REF=main`. Fine as a logistical item — just ensure the tag is pushed before the PR opens, or the build will fail on the maintainers' CI.

---

## Nits

### N1. README doesn't argue `field` as the "class equivalent"

The faithfulness rule requires "a class to encapsulate the sieve, or a (closest) equivalent feature." The README argues fresh-per-pass allocation and escape analysis but never explicitly states that `field` is Koru's closest equivalent to a class. Worth one sentence.

### N2. Dockerfile comment repeats the SIMD overclaim

`Dockerfile:3` — "the compiler GENERATES the SIMD marker." Same fix as B1.

---

## Answers to the brief's specific questions

**§4 Q1 — Is the faithfulness argument sound?** Defensible but not airtight. The comptime-size requirement for stack placement is the hole. A strict maintainer could argue the compiled behavior (stack array) doesn't meet "allocated dynamically at runtime."

**§4 Q2 — Is it presented honestly in the README?** Yes, the faithfulness section is candid about the wrinkle. The overclaim is elsewhere (SIMD), not in the faithfulness section.

**§4 Q3 — Would you submit `faithful=yes` or `faithful=no`?** Submit `faithful=yes` — the source semantics are faithful, and the optimization story parallels accepted JVM entries. But ship `solution_2` as `faithful=no` (reused buffer) as a fallback. Two solutions is consistent with existing entries (Zig, C++).

**§6 — Is the mark-multiples framing honest?** Yes. The program logic is in Koru; the compiler transform is a stdlib implementation detail. Not the kind of "calling into another language" the rule targets.

**§8 Item 1 — Validation line on stdout.** Move it to stderr. It's a trivial fix that doesn't touch the benchmarked path.

**§8 Item 2 — One solution or two?** Two. The `faithful=yes` entry is the interesting one; the `faithful=no` variant is the safe fallback and lets the maintainers choose.

---

## Summary

The submission is close. The two blockers are both honesty issues, not correctness issues — the sieve works (78,498 primes validated). Fix the SIMD overclaim (B1) and move the validation line to stderr (B2), then it's shippable. The `faithful=yes` tag is a judgment call that leans defensible but should have a `faithful=no` sibling entry as insurance.
