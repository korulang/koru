# Pattern Branches - Inverted Event/Flow Relationship

## Status: DESIGN / NOT IMPLEMENTED

## The Insight

Normal Koru: **Event declares branches → Flow must handle exhaustively**

Pattern Branches: **Flow declares branches → Transform generates from them**

This inverts the information flow. The tree structure in user code INFORMS the event, rather than the event constraining what branches exist.

## Syntax

```koru
~comptime_event()
| [pattern expression here] binding |> continuation
| [another pattern] binding |> continuation
```

The `[...]` contains opaque data interpreted by the comptime transform.

## Primary Use Case: Routing

```koru
~orisha:router()
| [GET /users/:id] r |>
    db.get_user(id: r.params.id)
    | found u |> ok { user: u }
    | not_found |> not_found "No user"
| [POST /users] r |>
    db.create_user(data: r.body)
    | created |> created {}
| [DELETE /users/:id] r |>
    auth.require(r)
    | authorized |> db.delete_user(id: r.params.id)
        | deleted |> no_content
    | unauthorized |> forbidden "Nope"
```

Benefits:
- All routes in one place
- Handler flows inline with route definition
- Middleware is explicit in flow (or nest for shared)
- Transform generates efficient dispatch

## Compiler Responsibilities

The compiler should:
- Parse `[...]` as opaque content (brace-counting)
- Pass pattern data to comptime transform
- NOT validate pattern semantics (transform decides)
- NOT reject duplicate patterns (may have meaning)

The transform decides:
- What patterns mean
- How to generate dispatch
- Whether duplicates are allowed
- What the binding receives

## Other Use Cases

State machines:
```koru
~state_machine()
| [idle -> running] |> start()
| [running -> stopped] |> cleanup()
```

Grammar definitions:
```koru
~grammar()
| [expr := term ('+' term)*] |> build_expr()
```

Any DSL where the user defines structure and transforms interpret it.

## Parser Change Required

Small change: allow `[...]` as branch name with brace-counting for nested brackets.

## Related

- Comptime transforms (existing)
- Expression parameters (existing)
- Taps with wildcards (similar pattern matching concept)
