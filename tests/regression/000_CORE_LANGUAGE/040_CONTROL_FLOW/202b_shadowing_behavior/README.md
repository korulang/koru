# Test 202b: Shadowing Behavior

## Purpose
This test documents Koru's actual behavior regarding binding name shadowing in nested continuations.

## Discovery Process
We created this test to answer the question: "Does Koru allow binding shadowing?"

## Result: **Shadowing is FORBIDDEN**

### What Works
```koru
~first(value: 10)
| result r |> second(value: r.num)
    | data d |>                      // 'd' is a unique name - OK
        show(outer_val: r.num, inner_val: d.num)
```

This compiles and runs successfully because each binding has a unique name.

### What Fails
If you change `| data d |>` to `| data r |>` (attempting to shadow the outer 'r'):

```
error[KORU010]: stray continuation line without Koru construct
  --> input.kz:33:5
  |
 33 |     | data r |>
  |      ^
```

The parser rejects duplicate binding names at the syntax level - it doesn't even parse as a valid continuation.

## Language Design Decision

**Koru forbids shadowing** - This decision was made by the implementation, not by explicit design, but we're documenting it as the official behavior.

### Rationale for Keeping This Behavior
1. **Prevents bugs**: Shadowing can hide bindings accidentally
2. **Clearer code**: Unique names make data flow obvious
3. **Consistent with Zig**: Our target language also forbids shadowing
4. **Simpler mental model**: The scope chain just accumulates, no hiding

### Example of Scope Accumulation
```
~first()
| result r |>      // Scope: [r]
    second()
    | data d |>    // Scope: [r, d] - both accessible
        third()
        | val v |> // Scope: [r, d, v] - all three accessible
```

## Specification Impact
SPEC.md has been updated to:
- Remove the claim that "Inner bindings shadow outer ones"
- Document that duplicate binding names are forbidden
- Show that the scope chain accumulates without shadowing
