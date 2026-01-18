# CODEX TASK: Implement Glob Matcher with Captures

## Your Mission

Implement `src/glob_matcher.zig` to make all tests in `src/glob_matcher_spec_test.zig` pass.

## Run Tests

```bash
cd /Users/larsde/src/koru
zig test src/glob_matcher_spec_test.zig
```

## What to Implement

The `match()` function that:
1. Takes a glob pattern and input value
2. Returns whether they match
3. Captures the parts that matched wildcards

### Pattern Types

| Pattern | Example | Input | Captures |
|---------|---------|-------|----------|
| Full wildcard | `*` | `anything` | `["anything"]` |
| Suffix glob | `log.*` | `log.error` | `["error"]` |
| Prefix glob | `*.io` | `std.io` | `["std"]` |
| Bare suffix | `ring*` | `ring[T:u32]` | `["[T:u32]"]` |
| Bare prefix | `*Handler` | `EventHandler` | `["Event"]` |
| Middle glob | `a.*.b` | `a.x.b` | `["x"]` |
| Multi-glob | `*.*.*` | `1.2.3` | `["1", "2", "3"]` |
| Mixed | `std.*.io.*` | `std.fs.io.read` | `["fs", "read"]` |

### Requirements

1. **Zero allocations** - Use the `_capture_storage` array in Match struct
2. **Captures are slices** - Point into the original input, don't copy
3. **Comptime compatible** - Should work in `comptime` blocks
4. **Handle edge cases** - Empty strings, no wildcards, special chars

### Algorithm Hints

For dot-separated patterns like `log.*` or `*.*.*`:
1. Split both pattern and value by `.`
2. Match segments pairwise
3. `*` segment matches any single segment
4. Capture each wildcard's matched value

For bare patterns like `ring*` or `*Handler`:
1. Check prefix/suffix accordingly
2. Capture the non-matching part

For mixed patterns like `*mid*`:
1. Find the literal part in the input
2. Capture before and after

### Files

- **Implement**: `src/glob_matcher.zig`
- **Tests**: `src/glob_matcher_spec_test.zig`
- **Reference**: `src/glob_pattern_matcher.zig` (simpler version without captures)

### Success Criteria

```
$ zig test src/glob_matcher_spec_test.zig
All 30 tests passed.
```

Good luck, square! 🤖
