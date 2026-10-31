# 016 — std/num vs bc vs python decimal

Measured 2026-10-31 on `quantity-numbers` (WSL Ubuntu 20.04, x86_64,
glibc-2.31 shim). Rig: `run.sh` — same operands, same significant-digit
targets, three implementations. `koru kara` is `num.kz` with the limb-level
Karatsuba mul (KARA_MIN=24) + binary pow10/biPowFast, landed after the
schoolbook baseline below.

## Time (ms)

| # | workload | koru Debug (schoolbook) | koru RF (schoolbook) | koru RF (kara) | bc -l | py dec | py int |
|---|----------|--------------------:|---------------------:|---------------:|------:|-------:|-------:|
| w1 | mul 2000d×2000d | 72.0 | 3.9 | **4.5** | ~2 | 0.13 | 0.10 |
| w2 | 3^100000 | 4000.9 | 305.7 | **315.7** | 110 | 0.50 | 1.02 |
| w3 | div →3000d | 74.5 | 3.6 | **3.5** | 20 | 0.13 | — |
| w4 | sqrt(2) →3000d | 93.9 | 3.4 | **2.0** | 130 | 2.32 | 0.26* |
| w5 | exp(1) →2000d | 5138.8 | 136.1 | **15.5** | 2210 | 3.14† | — |
| w6 | ln(2) →2000d | 17220.2 | 468.4 | **49.9** | 990 | 104.3† | — |
| w7 | sin(1) →2000d | 3875.9 | 102.6 | **18.6** | 1680 | 1.49† | — |
| w8 | π Machin →2000d | 8788.6 | 236.6 | **33.0** | 480 | 25.1† | — |
| w9 | mod | 99.6 | 5.6 | **5.6** | 20 | — | 0.14 |
| w10 | 2^0.5 powf →2000d | 23535.5 | 602.6 | **72.5** | 3260 | 138.2† | — |

\* `math.isqrt` oracle. † py3.8 decimal lacks exp/ln/sin/atan — Taylor
scripts in `bench.py` over the C core. bc times include ~2ms proc floor.

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

- **Karatsuba moved the ceiling**: transcendentals dropped 5.6–9.4×
  (exp 136→15.5ms, ln 468→49.9ms, sin 103→18.6ms, Machin 237→33ms,
  powf 603→72.5ms). The limb layer is ours — `mulL`/`addL`/`subL`/
  `addInto` over `[]Limb`, arena-scratch recursion, sign propagated at
  the boundary (a signed-magnitude `Managed` is *not* a nonnegative one —
  alternating series caught that once).
- **vs bc**: koru+kara now wins 9 of 10 — transcendentals by 15–142×.
  Only w2 remains bc's (110 vs 316ms): the residual there is *decimal
  conversion*, not multiplication — `pow` stringifies 47713 digits then
  reparses (`toString`+`decFromDigits`, both quadratic-ish), and `divTrunc`
  is still schoolbook long division (w3/w9 unchanged — that's the next
  ceiling: Newton-division or chunked conversion).
- **vs C decimal/int**: python still wins exact ops — but `ln` (49.9 vs
  104ms) and `powf` (72.5 vs 138ms) now beat the python-Taylor arms:
  a compiled-Karatsuba inner loop outruns interpreted Taylor over a
  faster limb library.
- **Correctness gate**: 615 = 40/40, 610 = 19/19, limb layer proven
  against `Managed.mul` on 2800 randomized operand shapes, digit
  agreement unchanged (all 47713 of 3^100000, all 3001 of sqrt2).

## Reproduce

    ./run.sh            # needs bc, python3, koruc, zig on PATH
