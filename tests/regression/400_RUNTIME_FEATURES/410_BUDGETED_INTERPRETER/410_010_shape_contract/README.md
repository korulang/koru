# Shape Contract Validation

Tests the ability to validate interpreted code against an event signature (contract).

## Motivation

When sending Koru code over the wire (e.g., HTTP handlers, RPC), we need to ensure
responses conform to a known shape. This prevents:

- Typos in branch names (`not_foundy` instead of `not_found`)
- Missing required fields
- Wrong field types
- Unexpected branches leaking through

## The Interface

```koru
// With contract validation
~std.runtime:run(source: CODE, scope: "api", budget: 100, shape: "handler")
| result r |>       // Success - code returned valid shape
| shape_error e |>  // Contract violation - e.branch, e.field, e.message

// Free-running mode (current behavior, no validation)
~std.runtime:run(source: CODE, scope: "api", budget: 100)
| result r |>       // r.branch can be anything
```

## Implementation Notes

The `shape` parameter is optional:
- If omitted: free-running mode, any branch constructor accepted
- If provided: validate all terminal points against the event's branches

Shape validation happens at parse/analysis time, NOT runtime:
1. Parse source to AST
2. Find all terminal branch constructors
3. Validate each against the shape event's declared branches
4. Return `shape_error` if any mismatch

This is the same validation the compiler does for subflow implementations.
