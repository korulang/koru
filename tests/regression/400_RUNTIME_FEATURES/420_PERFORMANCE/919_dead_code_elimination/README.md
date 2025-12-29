# Test 919: Dead Code Elimination for Optional Branches

## Feature Summary

When flows only handle a subset of optional branches, the compiler should eliminate code paths that lead exclusively to unhandled branches.

**Current behavior (Phase 3):**
```zig
// Handler includes ALL code paths, even for unused branches
pub fn handler(e: Input) Output {
    const len = e.data.len;

    if (len > 1000) {  // ← This whole block executes...
        // Expensive validation code
        // Even though no flow handles .warning!
        return .{ .warning = ... };
    }

    return .{ .success = ... };
}
```

**Desired behavior (Phase 4):**
```zig
// Handler ELIMINATES unused branch code
pub fn handler(e: Input) Output {
    const len = e.data.len;

    // No warning validation code at all!
    // Compiler detected no flows use .warning branch

    return .{ .success = ... };
}
```

## Benefits

1. **Zero-cost abstractions**: Optional branches are truly free when unused
2. **Smaller binaries**: Dead code removed at compile time
3. **Better performance**: No runtime checks for unreachable branches
4. **Compiler optimization**: Zig can further optimize without dead paths

## Verification

When this test passes, manually verify dead code elimination:

```bash
# Check the generated handler
grep -A 30 "pub fn handler" tests/regression/919_dead_code_elimination/output_emitted.zig

# Should NOT contain:
# - "bad_chars"
# - "non-ASCII"
# - "Short input"
# - Any warning/debug branch construction

# Should ONLY contain:
# - "Analyzed:"
# - Direct path to success branch
```

## Implementation Challenges

Phase 4 is the hard part because it requires:

1. **Control flow analysis**: Determine which return statements are reachable
2. **Branch tracking**: Map code paths to their branch outcomes
3. **Zig code parsing**: Understand embedded Zig code structure
4. **Conservative analysis**: Don't eliminate code unless provably dead

## Simplified MVP Approach

Start with straight-line returns only:

```zig
// EASY: Direct return statements (can eliminate)
if (cond) {
    return .{ .optional_branch = ... };
}

// HARD: Complex control flow (don't try to eliminate yet)
if (cond1) {
    if (cond2) {
        return .{ .optional_branch = ... };
    }
}
```

## Test Status

⏭️ **SKIPPED** - Phase 4 not yet implemented

Currently, the handler includes all code paths and uses `else => unreachable` in the flow switch.
