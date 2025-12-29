# Transform ".impl" Re-routing Pattern

This test documents the standard pattern for handling `[transform]` events that are replaced by inline code but must still satisfy the structural requirements of the Koru compiler.

## Problem
In Koru, subflow bodies must be a `Flow`. A `Flow` consists of an `Invocation` and its `Continuations`.
If an event like `print.ln` is marked as a `[transform]`, it often defines a `transformed` branch to handle the compile-time result:

```koru
~[transform]pub event print.ln { ... }
| transformed { program: *const Program }
```

After the transformation runs, the `print.ln` call is "replaced" by literal Zig code (via `inline_body`). However, the AST node still exists as a `Flow`. The `ShapeChecker` visits this node and, seeing the `print.ln` path, expects the `transformed` branch to be handled in the code.

## Solution: The ".impl" Pattern
Instead of trying to "delete" the branches (which would break the structural invariants of the `Flow` type), we **re-route** the invocation to a "dummy" or "void" event.

1.  **Define a Void Event**: Create a companion event (usually named `event_name.impl`) marked as `~[norun]` with NO branches.
2.  **Re-route in Transform**: The transform proc updates the `Invocation.path` to point to this `.impl` event.
3.  **Annotate**: Add `@pass_ran("transform")` to prevent the transform from running again on the re-routed node.

## Benefits
- **Clean Shape Checking**: The `ShapeChecker` sees an event with no branches, so it correctly requires no continuations.
- **Semantic Clarity**: It's clear that the original event was a "meta-event" that has been lowered into a "residue" implementation event.
- **Zero Runtime Cost**: Because the `.impl` event is `[norun]` and the `Flow` has an `inline_body`, the backend never actually emits a call to the `.impl` event.
