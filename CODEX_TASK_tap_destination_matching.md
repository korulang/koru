# CODEX TASK: Fix Tap Destination Pattern Matching

## Bug Summary

The tap pattern `~tap(* -> target)` should only fire when an event transitions TO `target`. Currently it fires for ALL flows because the destination pattern is parsed but never used.

**Smoking gun** in `koru_std/taps.kz` line 86:
```zig
_ = dest_is_wildcard; // TODO: use for destination matching
```

## Test Case

Test `310_037_tap_destination_matching` demonstrates the bug:

```koru
~tap(* -> target)
| Transition _ |> log()

~target()      // tap SHOULD fire (calls target)
| done _ |> _

~other()       // tap should NOT fire (doesn't call target)
| done _ |> _
```

**Expected:** TAP fires once (for target flow)
**Actual:** TAP fires 4 times (target, other, koru:start, koru:end)

## The Fix

### 1. Remove the suppression (line 86)

Change:
```zig
_ = dest_is_wildcard; // TODO: use for destination matching
```
To: (delete the line entirely - we'll use the variable)

### 2. Update `transformContinuations` signature

Current (line 511):
```zig
fn transformContinuations(
    alloc: std.mem.Allocator,
    continuations: []const ast.Continuation,
    tap_branches: []const ast.Continuation,
    is_meta: bool,
    mark_inserted: bool,
    source_event: ?[]const u8,
) !struct { conts: []ast.Continuation, modified: bool }
```

New:
```zig
fn transformContinuations(
    alloc: std.mem.Allocator,
    continuations: []const ast.Continuation,
    tap_branches: []const ast.Continuation,
    is_meta: bool,
    mark_inserted: bool,
    source_event: ?[]const u8,
    destination: []const u8,        // ADD: destination pattern
    dest_is_wildcard: bool,         // ADD: is destination a wildcard?
) !struct { conts: []ast.Continuation, modified: bool }
```

### 3. Add destination matching logic inside `transformContinuations`

Before wrapping a continuation (around line 578-591), add a destination check:

```zig
for (tap_branches) |*tap_cont| {
    const branch_matches = is_meta or std.mem.eql(u8, cont.branch, tap_cont.branch);
    if (!branch_matches) continue;

    // ADD: Check if destination matches
    if (!dest_is_wildcard) {
        // Only wrap if cont.node is an invocation matching destination
        if (cont.node) |step| {
            if (step == .invocation) {
                if (!pathMatches(destination, false, &step.invocation.path, null, alloc)) {
                    continue;  // Destination doesn't match, skip this continuation
                }
            } else {
                continue;  // Not an invocation, can't match destination
            }
        } else {
            continue;  // Terminal node, no destination to match
        }
    }

    // ... rest of wrapping logic unchanged
```

### 4. Update all call sites

Every call to `transformContinuations` needs the new parameters. Search for `transformContinuations(` and add `destination, dest_is_wildcard` to each call.

**Call sites to update:**

1. Line 528 (recursive call inside void branch handling)
2. Line 565 (recursive call for terminals)
3. Line 599 (recursive call for non-matching branches)
4. Line 648 (recursive call in nested invocation handling)
5. Line 716 (top-level flow transformation)
6. Line 772 (subflow_impl transformation)
7. Line 880 (module_decl flow transformation)
8. Line 934 (module_decl subflow_impl transformation)

### 5. Also update `transformNestedInvocations`

The `transformNestedInvocations` function (around line 607) also needs destination matching. It transforms nested invocations inside continuations.

Add `destination` and `dest_is_wildcard` parameters and apply the same matching logic.

## Verification

After the fix, run:
```bash
./run_regression.sh 310_037
```

Expected output should match `expected.txt`:
```
TAP: going to target
target called
other called
```

Also run the full tap test range:
```bash
./run_regression.sh 310
```

## Important Notes

1. **Don't break existing tests** - `~tap(source -> *)` with wildcard destination should still work
2. **Metatype handling** - When `is_meta=true`, we still need destination matching (metatypes observe specific transitions)
3. **Module context** - Use `flow.module` as fallback for `pathMatches` when checking destination
4. **Terminal handling** - For `cont.node == null` (terminals), destination matching doesn't apply (there's no next step)

## Files to Modify

- `koru_std/taps.kz` - The tap transform implementation

## Success Criteria

1. Test 310_037 passes
2. Test 310_026 gets closer to passing (may still have other issues)
3. No regressions in other tap tests (210_035, etc.)
