# Parser Bug: Multi-line Function Calls in Subflows

## The Bug

The parser fails to recognize continuation lines after multi-line function calls in subflow expressions.

**Current behavior:**
```
error[KORU010]: stray continuation line without Koru construct
  --> input.kz:XX:X
```

**What breaks:**
```koru
~my_subflow = step_a(x: 10)
| done a |> step_b(
    arg1: a.result,
    arg2: 20,
    arg3: 30
)
    | done b |> step_c(x: b.result)  // ← Parser fails here
        | done c |> final { result: c.result }
```

After the closing `)` on line 5, the parser doesn't recognize the `| done b |>` on line 6 as a continuation of the subflow expression.

## Root Cause

The parser loses track of the subflow context when parsing multi-line function arguments. After consuming the `)`, it doesn't maintain the state that indicates "we're still in a subflow expression".

## Expected Behavior

Multi-line function calls should work seamlessly in subflows. The parser should:
1. Track that it's inside a subflow expression (started by `~event_name =`)
2. Maintain that context through multi-line function arguments
3. Recognize continuation `|` lines after `)` as part of the subflow

## Comparison with Working Code

**This works (single-line calls):**
```koru
~my_subflow = step_a(x: 10)
| done a |> step_b(a: a.result, b: 20, c: 30)
    | done b |> step_c(x: b.result)
        | done c |> final { result: c.result }
```

**This should work but doesn't (multi-line calls):**
```koru
~my_subflow = step_a(x: 10)
| done a |> step_b(
    a: a.result,
    b: 20,
    c: 30
)
    | done b |> step_c(x: b.result)  // FAILS
        | done c |> final { result: c.result }
```

## Impact

This bug prevents writing readable, well-formatted subflows when events have many parameters. Users are forced to either:
1. Use ugly single-line calls with all parameters
2. Avoid subflows entirely and use procs with explicit Zig code

Neither is acceptable for a language aiming for clean, composable code.

## Test Discovery

This bug was discovered while implementing benchmark `2101b_nbody_granular`, which needed to call `assemble_solar_system()` with 5 body parameters:

```koru
~initialize_system = create_sun()
| created s |> create_jupiter()
    | created j |> create_saturn()
        | created sat |> create_uranus()
            | created u |> create_neptune()
                | created n |> assemble_solar_system(
                    sun: s.sun,
                    jupiter: j.jupiter,
                    saturn: sat.saturn,
                    uranus: u.uranus,
                    neptune: n.neptune
                )
                    | assembled a |> initialized { bodies: a.bodies }  // FAILS
```

## When Fixed

Remove the `MUST_FAIL` marker and verify the test compiles and runs successfully.
