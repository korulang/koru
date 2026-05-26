# Workload: nested_3_levels

## Question

Three nested generators/events of size N each. Total iterations = N³. Does dispatch cost compound per nesting level, or does the abstraction fuse?

## Shape

- Input: `n` (runtime argv), used as size for each level (total iterations = n³)
- Process: outer iterates 0..n; for each, mid iterates 0..n; for each, leaf iterates 0..n; consumer counts leaf yields
- Output: `counter = n³` to stdout

## Languages

- **Koru** — three separate `~pub event` definitions, each with an `! v` effect branch, nested in the consumer's handler body
- **Rust** — `.flat_map(|i| (0..n).flat_map(|j| (0..n)))` combinator chain
- **C#** — three `IEnumerable<ulong>` methods with `foreach` over the previous, yielding through

Skipping Python/JS for this workload — at the n values needed to be meaningful, runtime would be unreasonably long. The Koru/Rust/C# trio gives the dispatch-cost story.

## Expected output

For n=300: `counter = 27000000` (27 million)  
For n=1000: `counter = 1000000000` (1 billion)
