# Workload: regex_redos

## Question

What happens to match time on a pathological pattern as the input grows? The
classic ReDoS shape: pattern `(a+)+b` against input `"a" × n` (no `b`, so no
match). A backtracking engine explores an exponential number of ways to split
the `a`-run between the nested quantifiers before concluding "no match" — time
goes vertical around n≈25–30. A linear engine (DFA/NFA-simulation) walks the
input once — time stays flat into the millions.

Koru is flat BY CONSTRUCTION: the pattern is a compile-time DFA; there is no
backtracking code path to fall into. Go (RE2 lineage) and Rust (regex crate)
are also linear — they are the "engineered around it at runtime" comparison.
JS (V8 Irregexp) and Python (`re`) are backtracking — they are the cliff.

## Shape

- Input: `n` (runtime argv) — length of the `a`-run
- Process: build `"a" × n`, full-match it ONCE against `(a+)+b`
- Output: `matched = false len = n`

## The cliff — pick n per engine family

| Language | Engine family | Safe n |
|---|---|---|
| Koru | compile-time DFA | flat — tested to 10,000,000 |
| Go | RE2 (linear) | flat — tested to 10,000,000 |
| Rust | regex crate (linear) | flat — tested to 10,000,000 |
| JS | V8 Irregexp (backtracking) | cliff ≈ n=30; do NOT exceed 35 |
| Python | `re` (backtracking) | cliff ≈ n=25; do NOT exceed 30 |

The result chart is the same n-sweep for everyone (e.g. 10, 20, 25, 30, then
1000, 1,000,000 for the linear family). A backtracking row that would take
minutes is recorded as `timeout` — that IS the data point.

## Expected output

For n=30: `matched = false len = 30`
