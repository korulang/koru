# BUG 990: Slice Types from Imported Modules Generate Invalid Zig

## Status
**OPEN** - Blocks test 2006 (threading library)

## Symptom
When Koru generates Zig code for slice types containing imported module types, the syntax is malformed.

## Minimal Reproduction
```koru
~import $std/threading

~event getHandles {}
| got { handles: []const threading:WorkerHandle }
```

## Generated Zig (INVALID)
```zig
pub const Output = union(enum) {
    got: struct {
        handles: koru_[]const threading.WorkerHandle,  // ❌ ERROR!
    },
};
```

## Expected Zig
```zig
pub const Output = union(enum) {
    got: struct {
        handles: []const koru_threading.WorkerHandle,  // ✅ CORRECT
    },
};
```

## Root Cause
The code generator appears to:
1. Detect the type is from imported module (`threading:WorkerHandle`)
2. Prepend `koru_` prefix
3. Apply it to the wrong part of the type expression

The prefix should apply to the module name INSIDE the slice type, not to the slice itself.

## Impact
- Cannot return slices of imported types from events
- Cannot pass slices of imported types to events
- Blocks generic libraries like `$std/threading`

## Workaround
None currently. Possible workarounds:
1. Use wrapper types defined in same module
2. Return individual elements instead of slices
3. Use `*anyopaque` and cast (loses type safety)

## Fix Location
Likely in the Zig code emitter (backend), specifically where:
- Type names are resolved for imported modules
- Slice type syntax is generated
- Module prefixes (`koru_`) are applied

## Related
- Test 2006 (threading library) - BLOCKED by this bug
- Test 991 (array literal bug) - Related codegen issue
- `koru_std/threading.kz` - Needs this fix to work
