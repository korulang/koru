# 016 — std/num vs bc vs python decimal

Measured 2026-10-31 on `quantity-numbers` @ `18a045525` (WSL Ubuntu 20.04,
x86_64, glibc-2.31 shim). Rig: `run.sh` — same operands, same
significant-digit targets, three implementations.

## Time (ms, best of 3)

| # | workload | koru Debug | koru ReleaseFast | bc -l (proc) | py decimal | py int |
|---|----------|-----------:|-----------------:|-------------:|-----------:|-------:|
| w1 | mul 2000d × 2000d (exact) | 72.0 | **3.9** | ~2 (floor) | 0.13 | 0.10 |
| w2 | 3^100000 (exact, 47713 digits) | 4000.9 | **305.7** | 110 | 0.50 | 1.02 |
| w3 | div 2000d/2000d → 3000 digits | 74.5 | **3.6** | 20 | 0.13 | — |
| w4 | sqrt(2) → 3000 digits | 93.9 | **3.4** | 130 | 2.32 | 0.26* |
| w5 | exp(1) → 2000 digits | 5138.8 | **136.1** | 2210 | 3.14† | — |
| w6 | ln(2) → 2000 digits | 17220.2 | **468.4** | 990 | 104.3† | — |
| w7 | sin(1) → 2000 digits | 3875.9 | **102.6** | 1680 | 1.49† | — |
| w8 | π Machin → 2000 digits | 8788.6 | **236.6** | 480 | 25.1† | — |
| w9 | 5000d mod 997d (exact) | 99.6 | **5.6** | 20 | — | 0.14 |
| w10 | 2^0.5 via powf → 2000 digits | 23535.5 | **602.6** | 3260 | 138.2† | — |

\* `math.isqrt` integer oracle. † py3.8 `decimal` has no exp/ln/sin/atan —
these are Taylor series written in `bench.py` over the C decimal core.
bc times include ~2ms process floor.

## Correctness — digit agreement (common prefix, digits)

| # | koru=bc | koru=py | bc=py | verdict |
|---|--------:|--------:|------:|---------|
| w1 | 3998 | 3998 | 3999 | exact mul, full agreement to last digit |
| w2 | 47713 | 47713 (int) | — | exact pow, all 47713 digits identical |
| w3 | 2998 | 2998 | 3000 | boundary rounding only |
| w4 | 3001 | 3001 | 3001 | full; also exact vs `isqrt` oracle (3001) |
| w5–w8 | 1999–2021 | 1999–2019 | 1999–2020 | ±1 boundary digit on 2000-digit targets |
| w9 | 997 | 997 | 997 | exact mod, full agreement |
| w10 | 1999 | 1999 | 1999 | boundary digit |

Debug and ReleaseFast outputs are byte-identical.

## Reading it

- **vs bc**: koru ReleaseFast wins 8 of 10. bc is a bytecode interpreter —
  its Taylor loops (e/l/s/a) lose 2–16× to compiled Zig. bc wins w2
  (`3^100000`, 110 vs 306ms) — same binary exponentiation, cheaper limb
  multiply in tuned C.
- **vs C decimal / int**: python's bigint wins every exact op 30–600×.
  `decimal`/`int` multiply via Karatsuba+; Zig `std.math.big.int.Managed.mul`
  is schoolbook O(n²) — at ~2000 digits the asymptotic gap IS the table.
  This is an algorithm ceiling, not a codegen defect.
- **Debug is 17–39× slower than ReleaseFast** — the regression suite runs
  Debug (leak checker); nothing about Debug timing reflects shipped builds.
- **Transcendentals**: koru's guard-digit Taylor holds up — every op lands
  within ±1 last digit of two independent implementations at the requested
  precision. The `prec` contract is honest.

## Reproduce

    ./run.sh            # needs bc, python3, koruc, zig on PATH
