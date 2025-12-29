# Threading Library Test - Blocked by Codegen Bugs

## Status: BLOCKED ⚠️

This test demonstrates using `$std/threading` - a generic threading library based on the progressive disclosure pattern proven in test 2005.

**The library design is CORRECT and the pattern WORKS!**

However, we're hitting **codegen bugs** that prevent the test from compiling to valid Zig.

---

## What WORKS ✅

1. **Library exists**: `koru_std/threading.kz` with progressive disclosure:
   - `worker.spawn` (fire-and-forget)
   - `worker.spawn.async` (returns handle)
   - `worker.spawn.await` (wait for single)
   - `worker.spawn.join` (wait for multiple)

2. **Import works**: `~import $std/threading` resolves correctly

3. **Type checking passes**: All event calls type-check correctly

4. **Frontend compilation succeeds**: Koru → AST → validation all pass

---

## What's BLOCKED ❌

### Bug 1: Slice Types from Imported Modules

**Problem**: When generating Zig code, slice types from imported modules produce invalid syntax.

**Example**:
```koru
// In koru_std/threading.kz
pub const WorkerHandle = struct { ... };

~event collectHandles { ... }
| collected { handles: []const threading:WorkerHandle }
```

**Generated Zig** (INVALID):
```zig
handles: koru_[]const threading.WorkerHandle,  // ❌ Should be: []const koru_threading.WorkerHandle
```

**Impact**: Cannot return/pass slices of imported types

**Isolated in**: test 990_slice_type_imported_module (to be created)

### Bug 2: Array Literal Types with Imported Modules

**Problem**: Array literals with types from imported modules use `:` syntax in generated Zig.

**Example**:
```koru
~worker.spawn.join(handles: &[_]threading:WorkerHandle{ h1, h2, h3, h4 })
```

**Generated Zig** (INVALID):
```zig
.handles = &[_]threading:WorkerHandle{ h1, h2, h3, h4 }  // ❌ Should be: koru_threading.WorkerHandle
```

**Impact**: Cannot create arrays of imported types in flows

**Isolated in**: test 991_array_literal_imported_type (to be created)

---

## Workarounds Attempted

1. **✅ Use wrapper events for casts** - Works! (`castToOpaque` event)
2. **❌ Use inline array literals** - Fails (Bug #2)
3. **❌ Use slice return types** - Fails (Bug #1)
4. **🔄 Use proc subflow with Zig expressions** - Not yet tried (suggested by user)

---

## Solution Path

### Short-term: Fix Codegen

File these as regression tests in the 990 range:
- `990_slice_type_imported_module` - Isolated bug reproduction
- `991_array_literal_imported_type` - Isolated bug reproduction

Fix the code generator to:
1. Emit `[]const koru_modulename.TypeName` for slice types
2. Emit `koru_modulename.TypeName` in array literals

### Alternative: Proc Subflow Pattern

User suggestion: Define the main flow as a `~proc subflow` that can use Zig expressions (`@as`, `&[_]Type{...}`), then call it from top-level flow.

**Example**:
```koru
~proc mainFlow = createRing()
| created r |> spawnProducer(ring: r.ring)
    | spawned |> spawnConsumer(ring: r.ring, target: MESSAGES_PER_CONSUMER)
        | spawned ctx1 |> threading:worker.spawn.async(
            work_fn: consumerWorker,
            context: @as(*anyopaque, @ptrCast(ctx1.context))  // ✅ Zig expr allowed!
        )
        // ... spawn 3 more
        | awaitable h4 |> threading:worker.spawn.join(
            handles: &[_]koru_threading.WorkerHandle{ h1.handle, h2.handle, h3.handle, h4.handle }  // ✅ Zig expr allowed!
        )
        // ... rest

~mainFlow()  // Top-level call
```

**This might work TODAY** without any compiler fixes! Worth trying.

---

## What This Proves

**Progressive disclosure for threading CAN be expressed as a reusable library!**

- ✅ Pattern is sound
- ✅ Library design is correct
- ✅ Type system handles it
- ✅ Import system works
- ⚠️ Codegen needs fixes OR we need proc subflow pattern

Test 2005 proves the PATTERN works (inline).
Test 2006 proves the LIBRARY works (modulo codegen).

Once codegen is fixed (or proc subflow pattern is used), **Koru will have a real, working, generic threading library!** 🚀

---

## References

- **Working pattern**: test 2005_multi_consumer_async
- **Library source**: koru_std/threading.kz
- **Related bugs**: tests 990, 991 (to be created)
- **Blog post**: "Async Without the Color" explains the theory
