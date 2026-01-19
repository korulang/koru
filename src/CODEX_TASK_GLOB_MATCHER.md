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

## CRITICAL: Greedy Semantics

**`*` matches ANY characters including dots.** Dots have NO special meaning.

- `log.*` matches `log.error` AND `log.error.fatal` (captures: `["error.fatal"]`)
- `*.*.*` matches `a.b.c.d.e` (captures: `["a", "b", "c.d.e"]`)
- Each `*` captures **minimally** to allow the pattern to match
- The **last** `*` captures everything remaining (greedy)

### Pattern Types

| Pattern | Input | Captures | Notes |
|---------|-------|----------|-------|
| `*` | `anything.here` | `["anything.here"]` | Full greedy |
| `log.*` | `log.error.fatal` | `["error.fatal"]` | Greedy suffix |
| `*.io` | `std.io` | `["std"]` | Must END with `.io` |
| `ring*` | `ring[T:u32]` | `["[T:u32]"]` | Bare suffix |
| `*Handler` | `EventHandler` | `["Event"]` | Bare prefix |
| `a.*.b` | `a.x.b` | `["x"]` | Middle (minimal) |
| `*.*.*` | `a.b.c.d` | `["a", "b", "c.d"]` | Last gets rest |
| `*middle*` | `startmiddleend` | `["start", "end"]` | Two captures |

### Algorithm

The algorithm is simple - split pattern by `*` to get literal parts, then:

1. Check literals appear in order in the input
2. Capture what's between them
3. Each `*` (except last) matches **minimally** up to next literal
4. Last `*` matches **everything remaining**

Example: Pattern `*.*.*` → Literals: `["", ".", ".", ""]`
- Input `a.b.c.d`:
  - First `*`: match minimally until `.` → captures `"a"`
  - Second `*`: match minimally until `.` → captures `"b"`
  - Third `*`: match rest → captures `"c.d"`

### Requirements

1. **Zero allocations** - Use the `_capture_storage` array in Match struct
2. **Captures are slices** - Point into the original input, don't copy
3. **Comptime compatible** - Should work in `comptime` blocks
4. **Handle edge cases** - Empty strings, no wildcards, special chars

### Files

- **Implement**: `src/glob_matcher.zig`
- **Tests**: `src/glob_matcher_spec_test.zig`
- **Reference**: `src/glob_pattern_matcher.zig` (simpler version without captures)

### Success Criteria

```
$ zig test src/glob_matcher_spec_test.zig
All tests passed.
```

Good luck, square!
