# Validation Specification

> Branch coverage, phantom types, and compile-time safety guarantees.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-05
**Test Range**: 501-509

---

## Branch Coverage

Branch coverage ensures that all event branches are properly handled in flows.

### Complete Coverage

All non-optional branches must be handled:

```koru
~event process { value: u32 }
| success { result: u32 }
| error { msg: []const u8 }

// ✅ Complete coverage
~process(value: 10)
| success s |> handle_success(s)
| error e |> handle_error(e)
```

See: [501_branch_coverage_complete](../501_branch_coverage_complete/)

### Optional Branches

Branches marked with `?` don't require handling:

```koru
~event process { value: u32 }
| success { result: u32 }        // Required
| ?warning { msg: []const u8 }   // Optional

// ✅ Valid - only required branch handled
~process(value: 10)
| success s |> handle(s)
```

See: [918_optional_branches](../918_optional_branches/)

### Void Events

Events with no branches need no continuations:

```koru
~event log { message: []const u8 }

~proc log {
    std.debug.print("{s}\n", .{message});
    // No return - void event
}

// ✅ No branches to handle
~log(message: "Hello")
```

See: [502_void_event_no_branches](../502_void_event_no_branches/)

### Incomplete Coverage Error

Missing required branches fail at compile-time:

```koru
~event process { value: u32 }
| success { result: u32 }
| error { msg: []const u8 }

// ❌ ERROR: IncompleteBranchCoverage
~process(value: 10)
| success s |> handle(s)
// Missing 'error' branch!
```

**Error**: `error: IncompleteBranchCoverage - event 'process' has unhandled branches: error`

---

## Phantom Types

Phantom types provide zero-cost compile-time semantic differentiation.

### Phantom Tags (Value Types)

Tags for semantic meaning on value types:

```koru
i32[user_id]             // Semantic integer
[]const u8[email]        // Tagged string
f32[temp:celsius]        // Namespaced tag
```

**Key Properties**:
- Zero runtime cost (compile-time only)
- Required exact match in shape checking
- Namespaced when crossing module boundaries
- Erased in proc bodies (just the base type)

### Phantom States (Pointer Types)

States for compile-time tracking of pointer/resource states:

```koru
*Type[state]              // Single state
*Type[state1|state2]      // Union of states (INPUT ONLY)
```

**Key Rule**: Union states (`|`) are only allowed in event inputs, never in branch outputs.

### State Transitions

```koru
~event ssl.read { ctx: *SSL[connected|idle] }      // Union input ✅
| data { ctx: *SSL[connected], bytes: []u8 }       // Single state output ✅
| timeout { ctx: *SSL[idle] }                      // Different single state ✅

~event conn.send { conn: *Connection[ready], data: []const u8 }
| sent { conn: *Connection[ready] }                // Same state ✅
| blocked { conn: *Connection[congested] }         // State transition ✅
```

### State Forwarding

State variables enable state-agnostic operations:

```koru
*Type[S:state1|state2]    // State variable with constraints
*Type[S:_]                // State variable, any state
*Type[S]                  // Forward the captured state
```

**Example**:
```koru
~event encrypt {
    data: *Buffer[M:owned|borrowed|gc],  // M can be any of these
    key: *Key[K:_]                        // K can be any state
}
| encrypted {
    cipher: *Buffer[M],                   // Same memory model as input
    key: *Key[K]                         // Key state preserved
}

// Works with ANY combination:
~encrypt(data: owned_buf, key: active_key)    // M=owned, K=active
~encrypt(data: gc_buf, key: cached_key)       // M=gc, K=cached
```

**Forwarding Rules**:
1. If you capture a state variable, you must use it (forward or change)
2. States are type-local (can't forward `*Buffer[M]` to `*File[M]`)
3. State variables exist only in shape checking (zero runtime cost)

### Module-Qualified Phantom States

Phantom states are namespaced when crossing module boundaries:

```koru
// Inside ssl.kz
~pub event connect { host: []const u8 }
| connected { ctx: *SSL[connected] }     // Local state

// In application code
~import "$std/ssl"

~event use_ssl { ctx: *SSL[ssl:connected] }   // Namespaced state!
| done {}

~ssl:connect(host: "example.com")
| connected c |> use_ssl(ctx: c.ctx)    // ssl:connected matches!
```

**Namespacing Rules**:
- States defined in imported modules are prefixed with module name
- `*SSL[connected]` in ssl.kz becomes `*SSL[ssl:connected]` when imported
- Local code can define `*SSL[my_connected]` without conflict
- Enables composing multiple libraries with same type names

See: [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/)

### Phantom State Errors

**State Mismatch**:
```koru
~event process { file: *File[open] }
| done {}

~open_file(path: "data.txt")
| opened f |> process(file: f.file)  // f.file is *File[opened]
// ❌ ERROR: PhantomStateMismatch - expected *File[open], got *File[opened]
```

See: [508_phantom_state_mismatch](../508_phantom_state_mismatch/)

**Unknown Module**:
```koru
~event use_resource { res: *Resource[unknown:active] }
| done {}
// ❌ ERROR: UnknownPhantomModule - module 'unknown' not imported
```

See: [509_unknown_phantom_module](../509_unknown_phantom_module/)

---

## Shape Rules

### Structural Matching

Events define shapes (input → branches with payloads) that must match structurally at each flow step:

```koru
~event parse { input: []const u8 }
| success { ast: AST }
| error { msg: []const u8, line: usize }

// Shape-checked at compile-time
~parse(input: source)
| success s |> compile(ast: s.ast)    // s.ast must be AST type
| error e |> report(msg: e.msg, line: e.line)  // Fields must match
```

The compiler tracks shapes through the entire flow and validates:
- Input types match event signatures
- Branch outputs match continuation inputs
- Field types are compatible
- Phantom types align correctly

### Type Compatibility

Base types must match exactly:
- `u32` ≠ `i32`
- `[]const u8` ≠ `[]u8`
- `*Type` ≠ `Type`

Phantom types must match exactly (after namespacing):
- `i32[user_id]` ≠ `i32[post_id]`
- `*File[open]` ≠ `*File[closed]`
- `*SSL[ssl:connected]` ≠ `*SSL[connected]`

---

## Binding Scope Rules

### Scope Chain Model

Each continuation creates a binding that persists through ALL nested continuations:

```koru
~outer(x: 10)
| result r |> middle(y: r.value)                    // Scope: [r]
    | data d |> inner(z: d.val)                      // Scope: [r, d]
        | final f |> show(a: r.value, b: d.val, c: f.result)  // Scope: [r, d, f]
            | done |> _
```

At the `show` invocation, **all three bindings** (`r`, `d`, `f`) are accessible.

### Scope Persistence

**Bindings persist through ALL nested continuations**:

```koru
~fetch_user(id: 123)
| ok user |>                          // 'user' binding created
    validate(user.email)
    | valid |>                        // 'user' still accessible
        send_email(user.email)        // Can use 'user' here
        | sent |>                     // 'user' STILL accessible
            log(user.id)              // Can use 'user' at any depth
            | done |> _
```

**Parent bindings remain accessible at any depth**:

```koru
~step1()
| a data_a |>      // Scope: [data_a]
    step2()
    | b data_b |>  // Scope: [data_a, data_b]  ← data_a still visible
        step3()
        | c data_c |>  // Scope: [data_a, data_b, data_c]  ← all visible
            use_all(data_a, data_b, data_c)  // All three accessible
```

### Duplicate Binding Names

**Forbidden**: You cannot reuse a binding name in nested continuations.

```koru
~first()
| result r |>              // 'r' binding created
    process(r.value)
    | result r |>          // ❌ ERROR: 'r' already exists in outer scope
```

**Current implementation**: The Koru compiler currently allows duplicate bindings but the generated Zig code fails with "capture 'r' shadows capture from outer scope". This is a "lazy validation" approach - we let Zig catch the error.

**Future improvement**: The Koru compiler should validate binding uniqueness and produce clearer error messages pointing to the source .kz file.

See: [202_binding_scopes](../202_binding_scopes/)

---

## Compilation Guarantees

### Zero Runtime Cost

Phantom types are completely erased:
- No runtime overhead
- No memory footprint
- No performance impact
- Only affects compile-time checking

### Static Safety

All validation happens at compile-time:
- Branch coverage verified before code generation
- Phantom type mismatches caught early
- Shape incompatibilities detected
- No runtime type checks needed

### One-to-One Rule

- Every event MUST have exactly ONE implementation (proc, Koru-proc, or subflow)
- Implementation must be in same file as event declaration
- Name must match exactly

---

## Verified By Tests

- [501_branch_coverage_complete](../501_branch_coverage_complete/) - Complete branch handling
- [502_void_event_no_branches](../502_void_event_no_branches/) - Void events
- [503_multiple_events_mixed](../503_multiple_events_mixed/) - Mixed event types
- [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/) - Namespaced states
- [508_phantom_state_mismatch](../508_phantom_state_mismatch/) - State mismatch errors (negative test)
- [509_unknown_phantom_module](../509_unknown_phantom_module/) - Unknown module errors (negative test)

---

## Related Specifications

- [Core Language - Type System](../000_CORE_LANGUAGE/SPEC.md#type-system) - Base types
- [Core Language - Phantom Types](../000_CORE_LANGUAGE/SPEC.md#phantom-types) - Type-state basics
- [Optimizations - Optional Branches](../910_OPTIMIZATIONS/SPEC.md#optional-branches) - Optional branch syntax
- [Control Flow - Branch Coverage](../100_CONTROL_FLOW/SPEC.md#continuations) - Handling branches
