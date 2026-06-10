# Workload: regex_match

## Question

What does a regex classification dispatch cost when the patterns are known at
compile time? Koru's `~match` compiles each pattern branch to a specialized DFA
table matcher at COMPILE TIME — no runtime regex object, no generic engine
machinery, just a straight-line table walk per input byte feeding branch
dispatch. Go/Rust/JS/Python compile the pattern at runtime (hoisted out of the
loop, as is idiomatic) and match through their engine's runtime path. The
question is what compile-time specialization buys per dispatch.

All engines in this lineup except the backtracking ones (JS, Python) are
linear-time; this workload measures THROUGHPUT only. The pathological-input
axis lives in `regex_redos`.

## Shape

- Input: `n` (runtime argv)
- Process: for i in 0..n, classify `inputs[i % 3]` where inputs =
  `["foo@bar", "12345", "hello world!"]` against FULL-match patterns
  `[a-z]+@[a-z]+` (email), then `[0-9]+` (number), else none. First match
  wins — same first-match-wins dispatch order in every language.
- Output: `email = E number = N none = X` (each ≈ n/3)

Full-match semantics everywhere: Koru `match` is full-match by design (cut 1);
Go/Rust/JS anchor with `^...$`; Python uses `re.fullmatch`.

## Native vs emulated

| Language | Implementation | Compile-time specialized? |
|---|---|---|
| Koru | `~match` + backtick pattern branches → per-pattern native DFA fn | ✓ native |
| Go | `regexp.MustCompile` hoisted, `MatchString`, if/else chain | runtime (RE2, linear) |
| Rust | `regex::Regex::new` hoisted, `is_match`, if/else chain | runtime (linear, SIMD prefilters) |
| JS | regex literals, `.test()`, if/else chain | runtime (V8 Irregexp, backtracking) |
| Python | `re.compile` hoisted, `.fullmatch()`, if/else chain | runtime (backtracking) |

## Expected output

For n=3000000: `email = 1000000 number = 1000000 none = 1000000`

## Status

All five languages build and agree on output. The Koru hot loop
(`~for ! each i |> match(...)`) is the nested-`match` shape pinned green by
`tests/regression/600_STDLIB/640_REGEX/640_002_match_nested_in_for`.
