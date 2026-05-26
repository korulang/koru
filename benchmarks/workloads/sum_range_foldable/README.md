# Workload: sum_range_foldable

## Question

When the iteration's data flow is legible to the optimizer — yield `0..n`, sum into accumulator, output — can each language's compiler reduce the loop to a closed-form constant?

## Shape

- Input: `n` (provided as runtime argv to defeat trivial compile-time substitution)
- Process: producer yields each `i ∈ [0, n)`; consumer accumulates `acc + i`
- Output: `sum = <value>` to stdout

Wrap-around addition (u64) so overflow doesn't trap.

## Why this question matters

C# `IEnumerable` is a heap-allocated state machine — the JIT can't see through the per-iteration object dispatch. Python generators allocate generator objects. JS generators are similar.

Koru's effect-branch with resume value lowers to a comptime-specialized handler struct passed as a type parameter — the entire producer/consumer chain is visible to LLVM in one piece. **The question is whether LLVM uses that visibility to fold the iteration to a closed form** (`n*(n-1)/2`).

The interesting finding is which languages can fold this and which can't. Not which is "fastest."

## Expected output

```
sum = <n*(n-1)/2, u64 wrap>
```

For n=1000000000 → `499999999500000000`
