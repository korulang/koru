# Test 110: Transform Handlers Must Be Available at Compile-Time

## Purpose
Validates that transform handlers are emitted to backend_output_emitted.zig so they can run during Pass 2.

## What This Tests
- Compiler validation in `generateTransformHandlersToEmitter()`
- Error message clarity for annotation mistakes
- Prevention of silent transform failures

## Design Principle
**Transform handlers must exist in backend_output_emitted.zig to be callable during compilation.**

This happens either:
1. **Implicitly** via Source parameters (visitor_emitter treats them as comptime)
2. **Explicitly** via `[comptime]` annotation

## The Two Annotations Are Orthogonal
- `[comptime]` → **WHERE**: Explicitly emitted to backend_output_emitted.zig
- `[transform]` → **WHAT**: Declares transformation intent (picked up by run_pass)
- **Either Source parameters OR [comptime] required** for transforms to work

## Expected Behavior
Compilation MUST fail with error:
```
ERROR: Event 'badTransform' has [transform] annotation but won't be emitted to backend_output_emitted.zig

Transform handlers must be available at compile-time. This requires either:
  1. Source parameters (implicitly comptime): source: Source[...]
  2. [comptime] annotation (explicitly comptime)

Change to: ~[comptime|transform] event badTransform { ... }
Or add a Source parameter to make it implicitly comptime.
```

## Why This Matters
Without this validation, a user could write `[transform]` thinking it will work, but:
1. Event won't be emitted to backend_output_emitted.zig (no Source, no `[comptime]`)
2. Transform won't be available at backend compile time
3. Pass 2 compilation fails with cryptic error
4. User is confused

**Failing loudly at validation teaches the correct pattern immediately.**

## Valid Transform Patterns
- `~[transform]event foo { source: Source[...] }` ✅ Implicitly comptime
- `~[comptime|transform]event foo { source: Source[...] }` ✅ Explicitly comptime (redundant but allowed)
- `~[comptime|transform]event foo { count: i32 }` ✅ Explicitly comptime
- `~[transform]event foo { count: i32 }` ❌ Not emitted, invalid!
