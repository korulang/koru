# Codex Task: Nested Scope Auto-Discharge

## Problem

Test 330_016_scope_nested fails because phantom obligations created in an outer loop are not auto-discharged when the outer loop iteration ends.

## Test Case

See `input.kz`:

```koru
~for(0..2)
| each _ |>
    app.fs:open(path: "outer.txt")
    | opened _ |>
        for(0..2)
        | each _ |>
            app.fs:open(path: "inner.txt")
            | opened _ |> _  // Auto-close inner here (WORKS)
        | done |> _  // Auto-close outer here (BROKEN)
| done |> _
```

Note: `for` is a keyword (no module prefix needed). The `each` branch implicitly has `@scope` behavior - each iteration is independent.

## Current Behavior

- Inner file `g` is correctly auto-discharged at inner scope exit
- Outer file `f` is NEVER discharged - obligation is "lost"

## Expected Behavior

- Both files should be auto-discharged at their respective scope exits
- Output should show: open outer, open inner, close inner, close inner, close outer (for each outer iteration)

## Root Cause

In `src/auto_discharge_inserter.zig`, the `checkForeachNode` function processes scope branches and checks for obligations at scope exit (~line 813). However:

1. The transform-and-restart pattern means each modification returns `transformed=true`
2. The caller restarts processing from the beginning
3. Nested transformations (like synthetic binding replacement `_` → `_auto_N`) always find something to transform
4. The scope-exit check at line 813+ never runs because we return early

## Investigation Notes

Debug output showed:
```
[FOREACH] Processing body_cont[0]: transformed=true  <- always true
[SCOPE-EXIT] After processing branch body...         <- never reached
```

## Suggested Approach

The auto-discharge inserter needs to track scope-exit obligations separately from the transform-and-restart loop. Options:

1. **Two-phase approach**: First pass does all transformations, second pass inserts scope-exit disposals
2. **Deferred insertion list**: Accumulate scope-exit disposals during traversal, apply at end
3. **Separate scope-exit pass**: Run scope-exit insertion as a distinct pass after main auto-discharge

## Files to Modify

- `src/auto_discharge_inserter.zig` - main logic
- Specifically `checkForeachNode` (~line 765) and `checkAndTransformFlow` (~line 456)

## Acceptance Criteria

1. Test 330_016_scope_nested passes
2. Output matches expected.txt:
   ```
   Opening: outer.txt
   Opening: inner.txt
   Closing
   Opening: inner.txt
   Closing
   Closing           <- outer file closed here
   Opening: outer.txt
   Opening: inner.txt
   Closing
   Opening: inner.txt
   Closing
   Closing           <- outer file closed here
   ```
3. Existing auto-discharge tests still pass (330_001 through 330_015)

## Context

The `@scope` annotation marks loop branches as scope boundaries. Obligations created inside a scope should be discharged before the scope exits, even if there's no explicit terminal event.

The `BindingContext` tracks obligations with `scope_depth` and `loop_entry_scope`. The machinery for knowing WHAT to discharge exists - the problem is WHEN the insertion code runs.
