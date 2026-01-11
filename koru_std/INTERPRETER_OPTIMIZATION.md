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
