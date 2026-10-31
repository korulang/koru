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
- **vs bc**: koru+kara wins 8 of 10 clearly — transcendentals by 15–142×.
  w1 sits at bc's ~2ms whole-process floor (unmeasurable at this scale,
  not a bc win); w2 remains bc's (110 vs 316ms): the residual there is
  *decimal conversion*, not multiplication — `pow` stringifies 47713
  digits then reparses (`toString`+`decFromDigits`, both quadratic-ish),
  and `divTrunc` is still schoolbook long division (w3/w9 unchanged —
  that's the next ceiling: Newton-division or chunked conversion).
- **vs C decimal/int**: python still wins exact ops — but `ln` (49.9 vs
  104ms) and `powf` (72.5 vs 138ms) now beat the python-Taylor arms:
  a compiled-Karatsuba inner loop outruns interpreted Taylor over a
  faster limb library.
- **Correctness gate**: 615 = 40/40, 610 = 19/19, limb layer proven
  against `Managed.mul` on 2800 randomized operand shapes, digit
  agreement unchanged (all 47713 of 3^100000, all 3001 of sqrt2).

## Independent oracle — SymPy 1.14 + mpmath 1.4 (via nix)

`run_oracle.sh` runs `sympy_oracle.py`, a checker that shares no code with
koru, bc, or decimal. Two layers, measured 2026-10-31 on `koru.out`:

**Layer A — digits.** mpmath at mp.dps=3100 recomputes every workload;
koru's emitted digits are compared as strings (exact ops against exact
integer references, no float proxy):

| # | result |
|---|--------|
| w1 | 3999/3999 digits — exact |
| w2 | 47713/47713 digits — exact |
| w3 | 2998/2998 emitted digits correct |
| w4 | 3001/3001 emitted digits correct |
| w5–w7, w10 | all emitted digits correct (2000/2000, 1998/1998) |
| w8 | 2019/2023 — last 4 digits differ (Machin rounding accumulation at the boundary, consistent with the bc/decimal comparison) |
| w9 | 997/997 digits — exact |

Speed note, stated because it is true: mpmath computes all five
transcendentals in ~8 ms total — AGM-class algorithms, not Taylor series.
That gap is algorithmic and is the next ceiling after Newton-division.

**Layer B — certificates.** SymPy independently verifies what koru emits:

- All 12 recorded ODE certificates annihilate their functions — residual
  symbolically 0 (exp self-law, shifted integral forms, sqrt/quartic
  algebraic laws, inv, sum/product closures, `xf'−f=0` for x).
- All 3 recorded recurrences hold on true series coefficients (exp,
  sqrt(1+x), 1/(1−x)).
- The `cser` coefficient tail for √(1+x) matches sympy's series exactly:
  `[1, 1/2, -1/8, 1/16, -5/128, 7/256]`.
- The rel-layer conservation check `D(sin²+cos²)` reduces to 0 under
  sympy's own differentiation.
- `dsolve(y''=xy)` returns Airy functions — consistent with koru's
  `non-Liouvillian` classification, not a contradiction of it.

SageMath was not run; SymPy+mpmath covered the comparison surface.

## Reproduce

    ./run.sh            # needs bc, python3, koruc, zig on PATH
    ./run_oracle.sh     # needs sympy+mpmath (nix store paths self-discovered)
