# Metamorphic Re-routing Pattern

This test demonstrates an advanced compiler pattern where a `[transform]` event dynamically changes its own shape during lowering.

## The Concept: DSL-to-Implementation Mapping
In many cases, a high-level "DSL" event might not naturally match the branches of the lower-level implementation it lowers to. 

For example:
- **DSL**: `complex_op(val)`
- **Implementation**: `lowered_event(val) | high | low`

The user wants to write the DSL call but handle the implementation branches:
```koru
~complex_op(42)
| high |> ...
| low  |> ...
```

## How it Works
1.  **Parse Time**: The parser allows any branches to be attached to any invocation (it doesn't validate them yet).
2.  **Transform Time**: The `[transform]` for `complex_op` runs. It updates the `Invocation.path` and `Invocation.annotations` (to `@pass_ran("transform")`).
3.  **Analysis Time**: The `ShapeChecker` runs. It retrieves the *updated* path from the invocation. It finds `lowered_event` and sees that its branches (`high`, `low`) are correctly handled by the user's continuations.

## Why it's Clean
- **No Manual Mapping**: The transform doesn't have to manually map continuations; it simply changes the identity of the event, and the compiler's standard shape-checking logic handles the rest.
- **Natural DSLs**: You can hide internal implementation shapes behind beautiful, single-purpose meta-events.
- **Type Safety**: The `ShapeChecker` still ensures that the continuations provided by the user are EXACTLY what the lowered event requires.
