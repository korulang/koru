# Workload: sum_range_xor

## Question

Same iteration shape as `sum_range_foldable`, but the accumulator is XOR instead of addition. XOR-sum of `0..n` has a known closed form (4-cycle), but it's much less obvious for the optimizer than `n*(n-1)/2`. Does each language still fold?

## Shape

- Input: `n` (runtime argv)
- Process: producer yields `i ∈ [0, n)`; consumer accumulates `acc ^ i`
- Output: `xor = <value>` to stdout

## Why this question matters

Tests whether the optimizer's closed-form reduction is "small operation" or "any associative operation it can prove a closed form for." Sum has the most-trivial closed form; XOR has a less-obvious one. If languages that folded sum stop folding XOR, that locates the optimizer's ceiling.
