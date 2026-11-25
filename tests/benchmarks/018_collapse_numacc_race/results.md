# 018 — collapse-numacc race results

Measured 2026-11-25, WSL2 x86_64 (glibc-2.31 target), ReleaseFast,
tree: `collapse-num-custody` @ `da04c278a` + this bench dir.
Same `input.k` built twice — the only difference is the pass.

## collapsed (C3 numacc fires)

| n | fibn digits | fibn ms | lrec digits | lrec ms |
|---|---|---|---|---|
| 10 | 2 | 0.035 | 4 | 0.014 |
| 100 | 21 | 0.011 | 38 | 0.018 |
| 1,000 | 209 | 0.026 | 383 | 0.035 |
| 10,000 | 2,090 | 0.123 | 3,828 | 0.208 |
| 65,536 | 13,696 | **1.94** | 25,086 | **5.07** |

## uncollapsed (`KORU_COLLAPSE_OFF=1`)

| n | fibn ms | lrec ms |
|---|---|---|
| 10 | 0.038 | 0.025 |
| 100 | 0.099 | 0.262 |
| 1,000 | 1.78 | 8.70 |
| 10,000 | 233 | 1,575 |
| 65,536 | **44,254** | **330,180** |

## Reading

- Ratio at n=65,536: fibn ~22,800×; lrec ~65,000×. lrec's wider gap is
  limb-width²: pell values carry ~1.8× fib's digits, and every source
  step pays dup + 2×decParse + decToString over the whole string.
- Collapsed scaling tracks limb width × log₂(trip count): fibn is
  ~flat 10→1,000 then steps at each digit-width boundary; lrec 65536
  (25k digits ≈ 390 u64 limbs) costs ~2.6× fibn 65536.
- Uncollapsed is ~n^2.3 drifting up — conversion-bound, not add-bound.
