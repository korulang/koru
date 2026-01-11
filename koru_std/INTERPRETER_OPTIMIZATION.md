# Interpreter Optimization: Pre-allocated Flow State

## Current State (v1 - 24 hours)

- **Performance**: ~5x slower than Python
- **Bindings**: HashMap-based, allocated per-execution
- **Types**: String-only inputs, runtime parsing
- **Lookup**: Hash + string comparison per access

## The Insight

Koru flows are **typed entities**. When we parse:

```koru
~get_user(id: 42)
| found user |> get_permissions(user: user)
| ok perms |> check_access(user: user, perms: perms)
| granted |> done { }
```

We know from the **dispatch table**:
- `get_user` returns `| found { user: User }`
- `get_permissions` returns `| ok { perms: []Permission }`
- `check_access` returns `| granted { }`

This is a **Koru superpower**: the flow structure + dispatch table give us complete type information at parse time.

## The Design

### 1. Flow Analysis (Parse Time)

Walk the flow AST, collect binding info:

```zig
const BindingSlot = struct {
    name: []const u8,      // "user", "perms"
    type_id: TypeId,       // From dispatch table
    offset: usize,         // Byte offset in state buffer
    size: usize,           // Size of this type
};

const FlowLayout = struct {
    bindings: []BindingSlot,
    total_size: usize,
};

fn analyzeFlow(flow: *Flow, dispatch_table: *DispatchTable) FlowLayout {
    // 1. Walk flow, find all | branch binding |> patterns
    // 2. Look up return types from dispatch table
    // 3. Compute sizes and offsets
    // 4. Return layout
}
```

### 2. State Allocation (Once Per Flow)

```zig
// Allocate ONE buffer for entire flow execution
var state_buffer = allocator.alloc(u8, layout.total_size);
defer allocator.free(state_buffer);
```

### 3. Execution (Direct Offset Access)

```zig
// Dispatch writes to KNOWN offset
fn dispatchAndStore(
    event: Event,
    args: Args,
    state: []u8,
    slot: BindingSlot
) void {
    const result = dispatch(event, args);
    writeToOffset(state, slot.offset, result);
}

// Next dispatch reads from KNOWN offset
fn readBinding(state: []u8, slot: BindingSlot, comptime T: type) T {
    return readFromOffset(T, state, slot.offset);
}
```

### 4. No HashMap, No Lookup

Current:
```zig
// SLOW: Hash "user", lookup, return value
const user = env.get("user") orelse return error.BindingNotFound;
```

Proposed:
```zig
// FAST: Direct memory access
const user = @ptrCast(*User, state[user_slot.offset..]);
```

## Why This Works (Koru-Specific)

1. **Typed Flows**: `| branch binding |>` explicitly names bindings
2. **Dispatch Table**: Knows return types of all registered events
3. **Lexical Scoping**: Flow defines exact extent of bindings
4. **No Dynamic Binding**: Can't add bindings at runtime

Python/JS can't do this - they don't know types until execution.

## Expected Performance

| Operation | Current | Proposed |
|-----------|---------|----------|
| Binding allocation | HashMap alloc | Single buffer alloc |
| Binding write | Hash + insert | Direct offset write |
| Binding read | Hash + lookup | Direct offset read |
| Type dispatch | String comparison | Already know type |

**Estimated speedup: 10-50x** for binding operations.

The only remaining overhead is the actual event dispatch (calling the handler function).

## Implementation Steps

1. [ ] Add `analyzeFlow()` to compute `FlowLayout` at parse time
2. [ ] Look up return types from dispatch table during analysis
3. [ ] Allocate single state buffer based on layout
4. [ ] Modify `executeFlow()` to use offset-based access
5. [ ] Benchmark against current implementation

## Complex Types

This works for ANY type the dispatch table knows:

```koru
~query_db(sql: "SELECT * FROM users")
| rows data |> process(rows: data)
```

If `rows` returns `[]User` (a slice of structs), we pre-allocate space for the slice header (ptr + len). The actual row data lives elsewhere, but the binding slot is still fixed-size and pre-allocated.

## Nested Flows / For Loops

For loops create multiple iterations of bindings:

```koru
~for(0..100)
| each i |> process(n: i)
```

Options:
1. **Reuse slot**: `i` is overwritten each iteration (single slot)
2. **Stack allocation**: Push/pop for nested scopes

Since `| each i |>` overwrites `i` each iteration, we can reuse the same slot.

## The Vision

**Compiled data flow + Interpreted control flow**

- Memory layout: STATIC (computed at parse)
- Binding locations: STATIC (offsets)
- Type shapes: STATIC (from dispatch table)
- Field access: STATIC (direct offset)
- Event dispatch: DYNAMIC (call handler)

This could make Koru's interpreter the fastest for typed flow execution.

---

# IMPLEMENTATION SPECIFICATION

## The Gap: Type Metadata Not Exposed

**Current state** (`runtime.kz` line 232-239):
```zig
pub const ScopeEvent = struct {
    name: []const u8,
    dispatcher: DispatchFn,
};
pub const ScopeDescriptor = struct {
    name: []const u8,
    events: []const ScopeEvent,
};
```

**Problem**: The dispatcher DOES know types (via comptime reflection in the generated code), but that information isn't exposed to the interpreter. The interpreter can't ask "what does `get_user` return?"

## File Changes Required

### 1. `koru_std/runtime.kz` - Expose Type Metadata

#### 1.1 New Type Structures

Add after `ScopeDescriptor` (around line 239):

```zig
/// Describes a field in an event's return type
pub const FieldDescriptor = struct {
    name: []const u8,
    field_type: FieldType,
    size: usize,        // Size in bytes
    offset: usize,      // Offset within branch payload
};

pub const FieldType = enum {
    string,    // []const u8 - stored as slice (ptr + len = 16 bytes)
    int,       // i64 - 8 bytes
    float,     // f64 - 8 bytes
    bool,      // bool - 1 byte (padded to 8 for alignment)
};

/// Describes a branch in an event's return union
pub const BranchDescriptor = struct {
    name: []const u8,
    fields: []const FieldDescriptor,
    total_size: usize,  // Size of this branch's payload
};

/// Describes an event's complete return type
pub const EventTypeInfo = struct {
    event_name: []const u8,
    branches: []const BranchDescriptor,
    max_branch_size: usize,  // Largest branch payload (for allocation)
};

/// Extended scope event with type metadata
pub const ScopeEventTyped = struct {
    name: []const u8,
    dispatcher: DispatchFn,
    type_info: *const EventTypeInfo,
};

pub const ScopeDescriptorTyped = struct {
    name: []const u8,
    events: []const ScopeEventTyped,

    /// Look up type info for an event by name
    pub fn getEventTypeInfo(self: *const ScopeDescriptorTyped, event_name: []const u8) ?*const EventTypeInfo {
        for (self.events) |ev| {
            if (std.mem.eql(u8, ev.name, event_name)) {
                return ev.type_info;
            }
        }
        return null;
    }
};
```

#### 1.2 Modify Register Transform

In the `register` proc (starting around line 30), modify the generated code to include type metadata.

**Current generated code** (simplified):
```zig
fn dispatch_scope_event(inv, out) !void {
    const r = main_module.event_event.handler(buildInput(...));
    // ... reflection to extract fields ...
}
```

**New generated code** should ALSO generate:
```zig
const event_type_info = EventTypeInfo{
    .event_name = "event",
    .branches = &[_]BranchDescriptor{
        .{ .name = "ok", .fields = &[_]FieldDescriptor{
            .{ .name = "value", .field_type = .string, .size = 16, .offset = 0 },
        }, .total_size = 16 },
        .{ .name = "error", .fields = &[_]FieldDescriptor{
            .{ .name = "message", .field_type = .string, .size = 16, .offset = 0 },
        }, .total_size = 16 },
    },
    .max_branch_size = 16,
};
```

**How to generate this**: The `register` transform already uses comptime reflection to extract field types (lines 134-161). Extend this to ALSO emit the `EventTypeInfo` struct.

Key insight: At the point where we do:
```zig
inline for (dispatcher_std.meta.fields(T)) |field| {
    const T = field.type;
    if (T == bool) { ... }
    else switch (@typeInfo(T)) {
        .int => { ... },
        .float => { ... },
        .pointer => { ... },  // string
    }
}
```

We can ALSO emit the corresponding `FieldDescriptor` with:
- `field_type = .bool / .int / .float / .string`
- `size = @sizeOf(T)`
- `offset = @offsetOf(PayloadType, field.name)`

### 2. `koru_std/interpreter.kz` - Use Type Metadata

#### 2.1 New Structures for Pre-allocated State

Add after `InterpreterContext` (around line 241):

```zig
/// Slot in the pre-allocated state buffer
pub const BindingSlot = struct {
    name: []const u8,
    offset: usize,           // Byte offset in state buffer
    branch_desc: *const BranchDescriptor,  // Type info for this binding
};

/// Pre-computed layout for a flow
pub const FlowLayout = struct {
    slots: []const BindingSlot,
    total_size: usize,

    /// Find slot by binding name
    pub fn getSlot(self: *const FlowLayout, name: []const u8) ?*const BindingSlot {
        for (self.slots) |*slot| {
            if (std.mem.eql(u8, slot.name, name)) {
                return slot;
            }
        }
        return null;
    }
};

/// Pre-allocated state buffer for flow execution
pub const FlowState = struct {
    buffer: []u8,
    layout: *const FlowLayout,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, layout: *const FlowLayout) !FlowState {
        return .{
            .buffer = try allocator.alloc(u8, layout.total_size),
            .layout = layout,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FlowState) void {
        self.allocator.free(self.buffer);
    }

    /// Write a FieldValue to a binding slot
    pub fn writeField(self: *FlowState, slot: *const BindingSlot, field_name: []const u8, value: FieldValue) void {
        // Find field descriptor
        for (slot.branch_desc.fields) |fd| {
            if (std.mem.eql(u8, fd.name, field_name)) {
                const dest = self.buffer[slot.offset + fd.offset..][0..fd.size];
                switch (value) {
                    .string_val => |s| {
                        const slice_ptr: *align(1) []const u8 = @ptrCast(dest.ptr);
                        slice_ptr.* = s;
                    },
                    .int_val => |i| {
                        const int_ptr: *align(1) i64 = @ptrCast(dest.ptr);
                        int_ptr.* = i;
                    },
                    .float_val => |f| {
                        const float_ptr: *align(1) f64 = @ptrCast(dest.ptr);
                        float_ptr.* = f;
                    },
                    .bool_val => |b| {
                        dest[0] = if (b) 1 else 0;
                    },
                }
                return;
            }
        }
    }

    /// Read a field value from a binding slot
    pub fn readField(self: *const FlowState, slot: *const BindingSlot, field_name: []const u8) ?FieldValue {
        for (slot.branch_desc.fields) |fd| {
            if (std.mem.eql(u8, fd.name, field_name)) {
                const src = self.buffer[slot.offset + fd.offset..][0..fd.size];
                return switch (fd.field_type) {
                    .string => .{ .string_val = @as(*align(1) []const u8, @ptrCast(src.ptr)).* },
                    .int => .{ .int_val = @as(*align(1) i64, @ptrCast(src.ptr)).* },
                    .float => .{ .float_val = @as(*align(1) f64, @ptrCast(src.ptr)).* },
                    .bool => .{ .bool_val = src[0] != 0 },
                };
            }
        }
        return null;
    }
};
```

#### 2.2 Flow Analysis Function

Add new function to analyze a flow and compute its layout:

```zig
/// Analyze a flow AST and compute its memory layout
/// Requires a typed scope descriptor to look up return types
pub fn analyzeFlow(
    flow: *const ast.Flow,
    scope: *const ScopeDescriptorTyped,
    allocator: std.mem.Allocator,
) !FlowLayout {
    var slots = std.ArrayList(BindingSlot).init(allocator);
    var current_offset: usize = 0;

    // Walk the flow recursively, collecting all bindings
    try collectBindings(flow, scope, &slots, &current_offset, allocator);

    return FlowLayout{
        .slots = try slots.toOwnedSlice(),
        .total_size = current_offset,
    };
}

fn collectBindings(
    flow: *const ast.Flow,
    scope: *const ScopeDescriptorTyped,
    slots: *std.ArrayList(BindingSlot),
    offset: *usize,
    allocator: std.mem.Allocator,
) !void {
    // Get event name from invocation
    const event_name = if (flow.invocation.path.segments.len > 0)
        flow.invocation.path.segments[0]
    else
        return;

    // Look up type info for this event
    const type_info = scope.getEventTypeInfo(event_name) orelse return;

    // Process each continuation
    for (flow.continuations) |cont| {
        if (cont.binding) |binding_name| {
            // Find the branch descriptor for this continuation
            for (type_info.branches) |*branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    // Add slot for this binding
                    try slots.append(.{
                        .name = try allocator.dupe(u8, binding_name),
                        .offset = offset.*,
                        .branch_desc = branch,
                    });
                    offset.* += branch.total_size;
                    break;
                }
            }
        }

        // Recurse into nested flows
        if (cont.node) |node| {
            if (node == .invocation) {
                const nested_flow = ast.Flow{
                    .invocation = node.invocation,
                    .continuations = cont.continuations,
                    .module = flow.module,
                };
                try collectBindings(&nested_flow, scope, slots, offset, allocator);
            }
        }
    }
}
```

#### 2.3 Modified Execution Path

Add new optimized execution function alongside existing `executeFlow`:

```zig
/// Execute a flow using pre-allocated state (optimized path)
pub fn executeFlowOptimized(
    flow: *const ast.Flow,
    ctx: *InterpreterContext,
    state: *FlowState,
) !Value {
    // Similar to executeFlow, but:
    // 1. When binding results, use state.writeField() instead of env.bind()
    // 2. When reading bindings, use state.readField() instead of env.get()
    // 3. Skip all HashMap operations

    // ... implementation follows executeFlow structure ...
}
```

### 3. Integration: New `run_optimized` Event

Add a new entry point that uses the optimized path:

```zig
~pub event run_optimized {
    source: []const u8,
    scope: *const ScopeDescriptorTyped,  // Must be typed descriptor!
}
| result { value: Value }
| parse_error { message: []const u8, line: u32, column: u32 }
| validation_error { message: []const u8 }
| dispatch_error { event_name: []const u8, message: []const u8 }

~proc run_optimized {
    // 1. Parse source (same as run)
    // 2. Analyze flow to get layout: analyzeFlow(flow, scope, allocator)
    // 3. Allocate state: FlowState.init(allocator, &layout)
    // 4. Execute: executeFlowOptimized(flow, ctx, &state)
    // 5. Return result
}
```

## Backwards Compatibility

- Keep existing `ScopeEvent` and `ScopeDescriptor` for untyped usage
- Keep existing `run` event for HashMap-based execution
- New `run_optimized` requires `ScopeDescriptorTyped`
- Gradually migrate users to typed descriptors

## Testing Strategy

1. **Unit test `analyzeFlow`**: Given a flow AST and typed scope, verify correct layout
2. **Unit test `FlowState`**: Verify read/write operations work correctly
3. **Integration test**: Run same flow through both paths, verify identical results
4. **Benchmark**: Compare `run` vs `run_optimized` on nested loop benchmark

## Implementation Order

1. [ ] Add type metadata structures to `runtime.kz`
2. [ ] Modify `register` transform to generate `EventTypeInfo`
3. [ ] Add `ScopeDescriptorTyped` and lookup functions
4. [ ] Add `FlowLayout`, `FlowState`, `BindingSlot` to `interpreter.kz`
5. [ ] Implement `analyzeFlow()`
6. [ ] Implement `executeFlowOptimized()`
7. [ ] Add `run_optimized` event
8. [ ] Test with existing interpreter tests
9. [ ] Benchmark against Python

## Open Questions

1. **Alignment**: Should we pad all fields to 8-byte alignment for simpler pointer casts?
2. **String ownership**: Strings are slices pointing elsewhere - do we need to track lifetime?
3. **For loop slots**: Reuse single slot per iteration, or stack-allocate?
4. **Error handling**: What if flow uses an event not in the typed scope?
