# PrimeKoru Drag-Race Submission — Round 2 Adversarial Review

**Reviewer:** Composer (Cursor)  
**Date:** 2026-06-29  
**Verdict: FIX-FIRST** (one logistical blocker; Round 1 honesty fixes are solid)

Read the canonical files under `submission/PrimeKoru/solution_1/`, compiled and ran
`faithful.k` locally, and inspected emitted code. This is the Round 2 pass called for
in `REVIEW_BRIEF.md` § "Round 2 — for the second reviewer."

**Take no public action** — advisory only.

---

## Round 1 fix verification

### B1 — SIMD overclaim: **fixed and honest**

The submission README and Dockerfile no longer claim Koru "writes the SIMD." Wording
now says the compiler emits an unrolled, residue-specialized **scalar** marker, with
backend auto-vectorization called out explicitly (`README.md` lines 26–30).

**SHOWN:** emitted `output_emitted.zig` has **2,046** scalar `data[w + c] |= 0x…`
stores and **zero** `@Vector` in the final binary. The only `@Vector` path in
`field.kz` is in `strike`, which this sieve never calls. The corrected framing
matches the code.

### B2 — stdout/stderr: **fixed and verified**

`faithful.k` routes validation to `eprint.ln` and the official line to `print.ln`
(line 34). README Output section and Dockerfile comments match.

**SHOWN** (`./a.out 1>out 2>err` on local compile):

- **stdout:** `koru;86959;5.000047;1;algorithm=base,faithful=yes,bits=1` (only the
  official line)
- **stderr:** `validated primes: 78498`

### S1 — comptime-size wrinkle: **fixed**

README now states explicitly that stack placement fires only for a compile-time
constant size and what a runtime-sized variant would do (lines 54–59). Right level
of candor.

### N1 — `field` as class-equivalent: **fixed**

README lines 41–43 name `field` as Koru's closest equivalent to a class. Good.

---

## New finding (first pass missed)

### B3. `drag-race-v1` tag is stale — **blocker at PR time**

The Dockerfile defaults to `KORU_REF=drag-race-v1`, but:

1. **The tag is not on GitHub** (`git ls-remote` returns nothing).
2. **Locally it points at `f987cc17`**, which is *before* `f6cc32bc`
   (`feat(io): print family -> stdout, add eprint -> stderr`).

At `f987cc17`, `koru_std/io.kz` has **no** `eprint.ln`. The submission's
`faithful.k` will not compile against that ref, and even a workaround would
reintroduce the stdout/stderr bug.

The submission commits sit on top of the tag:

```
* e03e92a8  submission package
* f6cc32bc  io stdout/stderr fix      ← required
* f987cc17  ← drag-race-v1 currently here (wrong)
```

**Fix:** before opening the PR, move `drag-race-v1` to at least `f6cc32bc` (or a
dedicated release commit), push it to `korulang/koru`, and smoke-test:

```bash
docker build -t primekoru .
docker run --rm primekoru 1>out 2>err
```

Full Docker smoke-test was not completed in this review session (no `hadolint`;
default clone fails until the tag is pushed). The local compile/run path is green on
current `main`.

---

## Should-fix / nits (non-blocking for content quality)

### S4 — README format (should-fix)

README title is `# PrimeKoru solution_1 — Koru`; CONTRIBUTING template expects
`# <Language> solution by <YourUserName>` and a `## Run instructions` heading.
PrimeZig/Odin follow the template. Easy compliance win.

### S5 — Output label (should-fix)

Output label is `koru`; CONTRIBUTING says the label should be **at least your
username** (Odin uses `odin_bit_moe`, etc.). Consider `korulang` or the submitter's
GitHub handle — or a short disambiguator if you add `solution_2`.

### S6 — Internal README SIMD wording (nit)

`benchmarks/workloads/prime_sieve_drag_race/README.md` (outside the submission
package) still says "compiler-generated SIMD marker." Not submitted, but could
confuse if someone reads the repo while reviewing the PR.

### S7 — REVIEW_BRIEF §7 stale inline copy (nit)

`REVIEW_BRIEF.md` §7 still inlines the **pre-fix** README (SIMD wording, validation
on stdout). Fine as historical context, but label it "superseded" so a third
reviewer does not trip on it.

---

## Answers to the brief's crux questions

**§4 Q1 — Is the `faithful=yes` argument sound?**  
Defensible, not airtight. **SHOWN** in emitted code: per-pass `new` lowers to stack
placement via `new_instack_event` with a compile-time-sized
`__fld_buf: [(500000+63)/64]u64`. Source semantics are faithful; compiled behavior
is escape-analysis stack replacement (same category as accepted JVM entries). The
comptime-size requirement for that optimization is the hole a strict maintainer
could poke — and you now own it honestly in the README.

**§4 Q2 — Presented honestly?**  
Yes, after the B1 fix. The faithfulness section is candid; the marker section is
precise about scalar emission vs backend vectorization.

**§4 Q3 — `faithful=yes` or `faithful=no`?**  
Submit `faithful=yes` for `solution_1`. Keep `reuse.k` ready as `solution_2`
(`faithful=no`) — same advice as the first reviewer. Two solutions matches Zig/C++
precedent and gives maintainers a fallback if they read the comptime wrinkle
harshly.

**§6 — `mark-multiples` framing?**  
Still honest. The sieve logic, timing loop, and pass counting are Koru;
`mark-multiples` is a stdlib `[transform]` that lowers to native code at compile time
— not "calling Zig for the hot subroutine at runtime." Fair framing.

**§8 Item 1 — Extra stdout line?**  
Resolved. No longer a risk.

**§8 Item 2 — One or two solutions?**  
Still recommend two eventually; one clean `faithful=yes` entry is fine for an initial
PR if you want to minimize scope.

---

## Round 1 item status

| Round 1 item | Status |
|--------------|--------|
| B1 SIMD overclaim | Fixed |
| B2 stdout/stderr | Fixed (verified) |
| S1 comptime wrinkle | Fixed |
| N1 `field` = class | Fixed |
| S2 mark-multiples framing | Still honest |
| S3 tag at PR time | **Not done — and tag points at wrong commit** |

---

## Summary

The submission **content** is in good shape: correct sieve (78,498), honest README,
clean stdout, accurate marker claims. The remaining gate is **logistics**: retag and
push `drag-race-v1` (or change the default ref) so the Dockerfile actually builds the
toolchain `faithful.k` depends on.

**Pre-PR checklist:**

1. Move `drag-race-v1` → `f6cc32bc` or later; push to GitHub.
2. Docker smoke-test end-to-end on amd64 (and arm64 if you can).
3. Optionally align README title/sections with CONTRIBUTING template.
4. Decide on `solution_2` (`faithful=no` / `reuse.k`) before or shortly after
   opening the PR.

Once B3 is handled, upgrade verdict to **SHIP**.
