# BUG 991: Array Literals with Imported Types Use Invalid Zig Syntax

## Status
**OPEN** - Blocks test 2006 (threading library)

## Symptom
When creating array literals in flows using types from imported modules, the generated Zig code uses `:` syntax which doesn't exist in Zig.

## Minimal Reproduction
```koru
~import $std/threading

~makeHandle(id: 1)
| made h1 |> makeHandle(id: 2)
    | made h2 |> joinHandles(
        handles: &[_]threading:WorkerHandle{ h1.handle, h2.handle }
    )
```

## Generated Zig (INVALID)
```zig
const result_2 = joinHandles_event.handler(.{
    .handles = &[_]threading:WorkerHandle{ h1.handle, h2.handle }  // ❌ ERROR!
});
```

**Error**: `expected '}', found ':'`

The `:` character is Koru syntax for module qualification, but it's being copied verbatim into Zig code where it's invalid.

## Expected Zig
```zig
const result_2 = joinHandles_event.handler(.{
    .handles = &[_]koru_threading.WorkerHandle{ h1.handle, h2.handle }  // ✅ CORRECT
});
```

## Root Cause
The code generator appears to:
1. Parse array literal syntax in flow arguments
2. Extract type expression (`threading:WorkerHandle`)
3. Copy it verbatim to generated Zig without translating `:` to `.` and adding `koru_` prefix

## Impact
- Cannot use array literals with imported types in flows
- Cannot create inline arrays/slices of library types
- Blocks idiomatic usage of generic libraries

## Workaround
Create helper events that build arrays:
```koru
~event makeArray { h1: Handle, h2: Handle }
| made { array: []const Handle }

~proc makeArray {
    const arr = std.heap.page_allocator.alloc(Handle, 2) catch unreachable;
    arr[0] = h1;
    arr[1] = h2;
    return .{ .made = .{ .array = arr } };
}
```

Then use the helper instead of inline literals.

**OR** use `~proc flow =` which allows Zig expressions (untested).

## Fix Location
Likely in the Zig code emitter (backend), specifically where:
- Expression arguments are translated to Zig
- Array literal syntax is processed
- Module-qualified types are resolved

The fix should:
1. Detect module-qualified types in expressions (`:` syntax)
2. Translate to Zig module syntax (`.` with `koru_` prefix)
3. Apply recursively to nested type expressions

## Related
- Test 2006 (threading library) - BLOCKED by this bug
- Test 990 (slice type bug) - Related codegen issue
- `koru_std/threading.kz` - Needs this fix to work

## Alternative Solution
Allow `~proc flow = ...` syntax which permits Zig expressions directly:
```koru
~proc mainFlow = makeHandle(id: 1)
| made h1 |> makeHandle(id: 2)
    | made h2 |> joinHandles(
        handles: &[_]koru_threading.WorkerHandle{ h1.handle, h2.handle }  // ✅ Raw Zig!
    )

~mainFlow()  // Call from top-level
```

This bypasses the translation issue by allowing raw Zig syntax in proc flows.
