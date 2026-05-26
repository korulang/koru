# Workload: filter_map_reduce

## Question

When the user expresses "filter even, square, sum" — three composed operations across the yield abstraction — does the optimizer fuse them into a single pass, or pay dispatch per step?

## Shape

- Input: `n` (runtime argv)
- Process: producer yields `i ∈ [0, n)`; consumer filters even, squares, sums
- Output: `result = <sum of squares of evens in [0, n)>`

Closed-form: sum of `(2k)²` for k in `[0, n/2)` = `4·(n/2·(n/2-1)·(n-1))/6` for u64 wrap-around math.

## Why this question matters

Different languages express composition differently:
- Koru: single handler with `if/else` body inside
- Rust iterators: `.filter().map().fold()` — chain combinators, LLVM fuses
- C#: LINQ vs `yield return` + manual loop
- Python/JS: comprehension or filter-map-sum chain

Tests whether the language's composition pattern fuses to a single loop, and whether the optimizer can still find closed-form reductions through composed operations.
