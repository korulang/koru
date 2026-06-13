# regex_match_groups

Named-group **extraction**, the capture-path partner to `regex_match` (which
discards the payload). Each of `n` dispatches matches an `LxWxH` dimension
string against `(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)`, pulls the three groups
out as integers, and accumulates `l*w*h` so the extraction and the text→int
conversion can't be dead-code-eliminated. Inputs rotate over
`["2x3x4", "20x3x11", "hello world!"]` (two match, one doesn't).

All five implementations parse the named groups to ints and produce the
identical output, verified by the harness's output hash:

```
matched = 2000000  none = 1000000  total = 684000000   (n = 3,000,000)
```

## Result (Apple Silicon M-series, ReleaseFast; median of 5)

| Language | Engine | Median | vs Koru |
|---|---|---|---|
| **Koru** | compile-time **tagged DFA**, native | **111 ms** | 1.0× |
| Rust | `regex` crate (named captures) | 301 ms | 2.7× |
| JavaScript | V8 Irregexp | 324 ms | 2.9× |
| Go | `regexp` (RE2) | 401 ms | 3.6× |
| Python | `re` | 1,680 ms | 15× |

Koru's lead is *wider* here than on the discard path (2.0× there). Captures
compile to a one-pass tagged DFA — O(1) per byte, capture offsets recorded on
the transitions — because the grammar forbids groups under a quantifier or an
alternation, making capture positions structurally deterministic. See
`src/regex_engine.zig` (`buildTaggedDfa`).

## Run

```bash
./scripts/build.sh regex_match_groups
./scripts/run.sh   regex_match_groups <koru|rust|javascript|go|python> 3000000
```
