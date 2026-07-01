# Koru vs. PrimeRust/solution_1 — reproduction notes (2026-06-30/07-01)

Every number in this session was measured on a real DigitalOcean droplet, not
a laptop. This doc is the exact recipe to reproduce any of them on a fresh
box of the same spec. The droplets themselves were destroyed at the end of
this session (billing) — nothing below depends on them still existing.

## Hardware

Dedicated-CPU droplet, DigitalOcean `c-2` (2 vCPU, 4GB RAM, dedicated —
**not** a shared/burstable tier; that matters, see "Noise" below), region
`lon1`, Ubuntu 22.04. CPU: `Intel(R) Xeon(R) Platinum 8358 CPU @ 2.60GHz`
(checked via `lscpu`).

A second, larger droplet (`s-4vcpu-8gb-240gb-intel`, shared/burstable
"Basic Intel" tier, 4 vCPU/8GB/240GB) was used only for the full curated
185-language Docker harness run (disk-bound, not CPU-bound work) — numbers
measured *there* carry noticeably more run-to-run noise (stdev ~1,300-1,500
vs. ~30-80 on the dedicated box) because it's a shared-tenancy tier. Prefer
the dedicated `c-2`-class box for anything performance-sensitive.

## Toolchain versions

- Zig (koru's own build toolchain): **0.15.2**, official release from
  `ziglang.org`, `x86_64-linux`.
- Zig 0.8.0 (pinned, required only to build `PrimeZig/solution_3` as
  written — unrelated to this specific comparison but used earlier in the
  session): `zig-linux-x86_64-0.8.0`.
- Rust: installed via `rustup`, `--profile minimal`, which resolved to
  **rustc 1.96.1 (2026-06-26)** / **cargo 1.96.1**. `PrimeRust/solution_1`
  has no `rust-toolchain.toml` pinning an older version, so this floats
  with whatever's current stable.
- koru commit: **`00eeadad`** (origin/main as of this session — the
  allocator-swap + `DENSE_LIMIT` commits described below).

## 1. Building Koru's `faithful.k`

```bash
# koru itself, from source:
git clone https://github.com/korulang/koru.git
cd koru
zig build                      # produces zig-out/bin/koruc

# the sieve entry (submission copy):
cp benchmarks/workloads/prime_sieve_drag_race/submission/PrimeKoru/solution_1/faithful.k /tmp/bench/
cd /tmp/bench
/path/to/koru/zig-out/bin/koruc faithful.k
./a.out
# stdout: korulang;<passes>;<seconds>;1;algorithm=base,faithful=yes,bits=1
# stderr: validated primes: 78498
```

**Do not compile from the koru repo root** — `koruc` writes `backend.zig`,
`build.zig`, `a.out`, etc. into the current directory and will clobber the
tracked `build.zig`. Always compile in a scratch directory.

## 2. Building PrimeRust/solution_1 correctly — the trap we hit

`PrimeRust/solution_1/` is a Cargo **workspace**: the real release profile
(`opt-level=3`, `lto=true`, `codegen-units=1`) lives in the **workspace
root** `Cargo.toml`, not inside `prime-sieve-rust/`'s own `Cargo.toml`. If
you copy/tar only the `prime-sieve-rust/` and `helper-macros/`
subdirectories (as we did, the first time) and run `cargo build --release`
from inside `prime-sieve-rust/`, Cargo treats it as its own standalone
workspace and silently uses cargo's *default* release profile —
`opt-level=3` but **no LTO, no `codegen-units=1`**. This produced real,
wrong numbers earlier in this session (later corrected) — a smaller
apparent Koru lead, and a much larger apparent Rust binary.

**Correct steps:**

```bash
# copy ALL THREE: the workspace root Cargo.toml + both member dirs
cp Primes/PrimeRust/solution_1/Cargo.toml   /tmp/rustsol1/
cp -r Primes/PrimeRust/solution_1/prime-sieve-rust /tmp/rustsol1/
cp -r Primes/PrimeRust/solution_1/helper-macros    /tmp/rustsol1/
cd /tmp/rustsol1
cargo build --release
```

**Verify LTO actually applied** (don't trust the `Cargo.toml` alone — confirm
the real rustc invocation):

```bash
touch prime-sieve-rust/src/main.rs
cargo build --release -v 2>&1 | grep "crate-name prime_sieve_rust" \
  | tr ' ' '\n' | grep -E "opt-level|lto|codegen-units"
# must show: opt-level=3 / lto / codegen-units=1
```

Run the two variants that place 1st/2nd in the curated comparison:

```bash
target/release/prime-sieve-rust --bits-extreme  -t 1 -s 5   # "extreme-hybrid"
target/release/prime-sieve-rust --bits-unrolled -t 1 -s 5   # "unrolled-hybrid"
```

## 3. Runtime comparison protocol (the discipline that mattered)

- **Single-threaded only** (`-t 1` for Rust; Koru's entry is inherently
  single-threaded): matches the `threads=1` category everything else here
  is filtered to.
- **n=20 minimum**, both binaries, back-to-back, same box, same session —
  report mean, median, stdev, min/max. n=3 on a noisy/shared box produced a
  wrong "Koru is behind" conclusion earlier in this session; it wasn't
  wrong data, it was too little of it on too noisy a box.
- **Bare metal, not Docker**, for head-to-head numbers — Docker overhead is
  real and was measured to be asymmetric (cost Koru ~4.2% vs. Rust's
  ~1.85% in one measurement), so a Docker-run number for one side and a
  bare-metal number for the other is not a fair comparison. (The official
  drag-race harness *does* run everything through Docker — that's a
  legitimate, different number, just don't mix it with a bare-metal one.)
- **Welch's t-test on the two samples** before claiming a winner. A visible
  gap in the means with overlapping distributions and low sample count is
  not evidence; `t > ~2` for 95% confidence is the bar we used.

**Results this session (x86_64, dedicated CPU, bare metal, n=20 each,
Koru at `DENSE_LIMIT=128`, Rust properly LTO'd):**

| | mean passes/5s | median | stdev |
|---|---:|---:|---:|
| Koru (`faithful.k`, 35 lines) | 49,604.10 | 49,602.0 | 35.02 |
| Rust `--bits-extreme` (was ranked #1 in the curated 48-entry table) | 49,374.00 | 49,391.0 | 73.24 |
| Rust `--bits-unrolled` (was ranked #2) | 49,251.65 | 49,267.0 | 77.84 |

Koru ahead of both: +0.47% (Welch t=12.68) and +0.72% (Welch t=18.47).

## 3b. Re-verifying against Zig sol3 after the DENSE_LIMIT change — a mistake caught before publishing

The `DENSE_LIMIT` widening (section 3 above, done to close the gap to Rust)
is a general change to `mark-multiples` — it isn't specific to competing
with Rust. We didn't re-check its effect against `PrimeZig/solution_3`
until writing up the results, and almost published a stale number from
*before* the widening (~+2%, "dead even"-ish). Caught it, re-ran:

```bash
# PrimeZig/solution_3, built as in section elsewhere in this doc (zig 0.8.0,
# `zig build -Drelease-fast`, then run the specific spec line directly:
./zig-out/bin/PrimeZig -l 51   # "best singlethreaded base runner"
```

Same protocol as everything else (n=20, bare metal, dedicated CPU, current
koru `origin/main`):

| | mean passes/5s | median | stdev |
|---|---:|---:|---:|
| Koru (current, `DENSE_LIMIT<=128`) | 49,281.20 | 49,274.0 | 73.66 |
| Zig sol3 | 45,734.90 | 45,731.0 | 60.37 |

**+7.75%** (Welch t=166.52, zero overlap across both twenty-sample sets) —
not the ~2% figure from before the dense-marker widening. Lesson: a
performance-relevant code change invalidates *every* comparison measured
before it, not just the one it was made for. Re-check all of them, not just
the one you were optimizing against.

## 4. Binary size comparison

```bash
ls -la a.out                                    # koru, unstripped
ls -la target/release/prime-sieve-rust           # rust, unstripped
cp a.out koru_stripped.bin  && strip koru_stripped.bin
cp target/release/prime-sieve-rust rust_stripped.bin && strip rust_stripped.bin
```

Both binaries are dynamically linked (`ldd` confirms: koru links only
`libc.so.6`; rust also links `libgcc_s.so.1`), both unstripped-by-default
(neither `-Dstrip` nor a stripped cargo profile was set) — a fair
like-for-like starting point.

| | unstripped | stripped |
|---|---:|---:|
| Koru | 1,228,224 | 171,464 |
| Rust (properly LTO'd) | 1,309,664 | 1,129,544 |

**Caveat that must travel with this number**: Rust's binary bundles all 14
sieve variants in `PrimeRust/solution_1` (`--bits`, `--bits-extreme`,
`--bits-rotate`, `--bits-striped`, `--bits-striped-blocks`,
`--bits-striped-hybrid`, `--bits-unrolled`, `--bytes`, ...) plus
`structopt`/`clap` CLI parsing plus both single- and multi-threaded runner
orchestration. Koru's binary is exactly one fixed program. This is real,
measured, and not apples-to-apples on scope — say so every time this number
is quoted.

## 5. Compile-time comparison

```bash
# KORU cold: fresh .zig-cache
rm -rf .zig-cache backend.zig backend_output_emitted.zig build_backend.zig \
       build.zig output_emitted.zig a.out program.ast.json
time koruc faithful.k

# KORU warm: same dir, .zig-cache intact, only strip the generated outputs
rm -f backend.zig backend_output_emitted.zig build_backend.zig build.zig \
      output_emitted.zig a.out program.ast.json
time koruc faithful.k

# RUST cold: full dependency rebuild
cargo clean && time cargo build --release

# RUST warm: touch the one file that changed, incremental
touch prime-sieve-rust/src/main.rs && time cargo build --release
```

| | Koru (n=3) | Rust (n=3) |
|---|---:|---:|
| Cold | 10.14s mean (10.11/10.15/10.17) | 26.97s mean (26.89/27.01/27.01) |
| Warm | 5.09s mean (5.09/5.09/5.10) | 15.49s mean (15.46/15.47/15.51) |

Koru ~2.66× faster cold, ~3.04× faster warm. Rust's cold time is dominated
by building `syn`/`quote`/`proc-macro2`/`clap`/`structopt` from scratch —
the same dependency weight that shows up in the LOC and binary-size
comparisons, showing up a third time here.

**Methodology note**: "warm" means something slightly different on each
side. Rust's warm run recompiles only the one crate that changed
(dependencies stay built). Koru's warm run reuses Zig's own `.zig-cache`
for the backend build (Stage B) without changing `faithful.k` between
runs — but Stage B's inputs (compiler internals + `koru_std`) don't depend
on the user's file content anyway, so this is still representative of real
iteration: edit `faithful.k`, Stage A/C redo their small part, Stage B's
cache holds regardless. State this distinction explicitly if quoting the
number — don't imply the two "warm" runs used identical methodology.

## 6. The allocator finding (why any of this needed fixing first)

Full writeup lives in commit `58647308` ("koru_allocator() backs onto
c_allocator, not GeneralPurposeAllocator") and the earlier commit
`f6c813e4`. Short version: Zig's `DebugAllocator`/`GeneralPurposeAllocator`
unconditionally `munmap`s a bucket's backing page the instant its last live
slot is freed — verified via `verbose_log` on an isolated allocator probe,
not assumed. Confirm with `perf stat -e page-faults`:

```bash
perf stat -e instructions,cycles,page-faults ./a.out
```

Before the fix: ~404,478 page-faults / 3s, ~20% of wall-clock in syscall
time. After: ~174 page-faults / 3s, 0% sys time. This is the change that
made every other number in this doc possible — before it, Koru's own
`faithful=yes` entry was ~26% slower than it needed to be, independent of
anything about Rust or Zig.

## Droplet teardown

Both droplets used this session (`koru-bench`, `koru-drag-race`) were
destroyed via `doctl compute droplet delete <id>` once this document was
written. Nothing above depends on them still existing — every step is a
fresh-box recipe.
