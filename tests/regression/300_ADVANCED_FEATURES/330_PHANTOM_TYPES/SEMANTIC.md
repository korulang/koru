# Semantic Phantom Type Checker

> Resource lifecycle tracking through field name identity

**Parent**: [Phantom Types SPEC](./SPEC.md)

---

## Overview

The **semantic checker** is the default phantom type system in Koru. It tracks resource lifecycles by treating phantom states as resource states that transition through well-defined events.

---

## Identity Model

### Binding.Field = Identity

Resources are identified by the combination of:
- **Binding name** - The variable bound in a continuation
- **Field name** - The field accessed on that binding

```koru
| opened f1 |>  // Identity: "f1.file"
    write(f1.file)
    | written w1 |>  // Identity: "w1.file" (continues f1.file through "file" field name)
```

### Identity Continuity

When an event has the **same field name** in input and output, it's the same resource:

```koru
~event write { file: *File[open], data: []u8 }
| written { file: *File[open] }  // Same field "file" = same resource
```

The compiler tracks:
- Input: `binding.file` with state `[open]`
- Output: `new_binding.file` with state `[open]`
- These refer to the **same underlying resource**

### Multiple Resources

Different field names = different identities:

```koru
~event open_two {}
| opened { file1: *File[open!], file2: *File[open!] }

| opened o |>
    close(o.file1)  // Closes file1
    | closed c1 |>
        read(o.file2)  // ✅ file2 still open
        read(o.file1)  // ❌ file1 is closed
```

---

## State Transitions

### Valid Transition

When phantom states match:

```koru
~event open {}
| opened { file: *File[open!] }

~event close { file: *File[open] }
| closed { file: *File[closed] }

~open()
| opened o |> close(o.file)  // ✅ [open!] matches [open]
    | closed c |> _
```

### Invalid Transition

When phantom states don't match:

```koru
~open()
| opened o |> close(o.file)
    | closed c |> close(c.file)  // ❌ [closed] doesn't match [open]
```

---

## Binding Invalidation

### The Problem

When a resource's state changes, old bindings become stale:

```koru
| opened o |>  // o.file: [open]
    close(o.file)
    | closed c |>  // c.file: [closed]
        read(o.file)  // ❌ Should this be allowed?
```

### The Rule

**Once a binding is used in a state-changing event, it becomes invalidated in all child scopes.**

The compiler tracks:
1. `o.file` passed to `close()` which changes `[open]` → `[closed]`
2. `o.file` is **phantom-invalidated** after this point
3. Must use `c.file` instead (the continuation with correct state)

```koru
| opened o |>
    close(o.file)    // Invalidates o.file
    | closed c |>
        use(o.file)  // ❌ COMPILE ERROR: o.file phantom state invalidated
        use(c.file)  // ✅ OK: c.file has current phantom state
```

---

## Cleanup Obligations (!)

### Syntax

The `!` suffix marks states requiring cleanup:

```koru
*File[fs:open!]  // Requires cleanup
*File[fs:closed] // No cleanup needed
```

### Enforcement

**IMPLEMENTED** - See tests 513-521 for working examples:
- Test 514: Basic cleanup satisfaction
- Test 515: Disposal consumes obligations (`[!state]` syntax)
- Test 516: Use-after-disposal detection
- Test 517: Obligations escape through interfaces
- Test 518: Obligations lost at boundaries
- Test 520-521: Multiple resource tracking

---

## Examples

### File Lifecycle

```koru
~event fs:open { path: []const u8 }
| opened { file: *File[fs:open!] }
| not_found {}

~event fs:read { file: *File[fs:open] }
| data { file: *File[fs:open], content: []u8 }

~event fs:close { file: *File[fs:open] }
| closed { file: *File[fs:closed] }

// Usage:
~fs:open(path: "/etc/passwd")
| opened o |>
    fs:read(o.file)
    | data d |>
        process(d.content)
        | done |> fs:close(d.file)  // Must cleanup!
            | closed |> _
| not_found |> log_error()
```

### Multiple Resources

```koru
~event db:connect {}
| connected { read_conn: *Conn[db:open!], write_conn: *Conn[db:open!] }

~event db:close { conn: *Conn[db:open] }
| closed { conn: *Conn[db:closed] }

~db:connect()
| connected c |>
    db:close(c.read_conn)  // Close one
    | closed c1 |>
        use(c.write_conn)  // ✅ Other still open
        db:close(c.write_conn)
        | closed c2 |> _
```

### Generic States (State Variables)

```koru
~event process<M'owned|borrowed> { data: *Data[M] }
| done { data: *Data[M] }  // Preserves state

// Works with owned:
~alloc()
| allocated a |>  // a.data: [owned]
    process(a.data)
    | done d |>  // d.data: [owned]

// Works with borrowed:
~borrow(other_data)
| borrowed b |>  // b.data: [borrowed]
    process(b.data)
    | done d |>  // d.data: [borrowed]
```

---

## Implementation Notes

### Current Status

- ✅ Phantom syntax parsing
- ✅ Module-qualified states
- ✅ State compatibility checking
- ✅ State variable parsing
- ✅ Cleanup obligation enforcement (tests 513-521)
- ⚠️ Identity tracking (semantic concept, not enforced yet)
- ❌ Binding invalidation (not implemented)

### Future Work

**Identity Tracking**:
- Track binding.field identities through flows
- Detect when resources are consumed by state-changing events
- Invalidate old bindings in child scopes
- Require using fresh bindings with correct states

**Error Messages**:
When identity tracking is implemented, errors should be clear:
```
Error: Phantom state invalidated
  | opened o |>
      close(o.file)
      | closed c |>
          read(o.file)
               ^^^^^^^ o.file has phantom state [fs:closed] but was invalidated here

  Note: o.file was passed to close() which changed its state
  Help: Use c.file instead, which has the current phantom state
```

---

## Design Rationale

### Why Field Names?

Field names provide a **natural identity token** that:
- Already exists in the code (no new syntax)
- Has semantic meaning (same name = same conceptual resource)
- Works with shorthand syntax (`| f |> close(f.file)`)
- Scales to multiple resources (`file1`, `file2`)

### Why Binding.Field?

The binding distinguishes between multiple instances of the same resource type:
```koru
~open("a.txt")
| opened f1 |>
    open("b.txt")
    | opened f2 |>
        // f1.file ≠ f2.file even though both are "file"
```

### Why Invalidation?

Without invalidation, you could use stale bindings:
```koru
| opened o |>
    close(o.file)
    | closed c |>
        write(o.file, data)  // Writing to closed file!
```

The compiler should prevent this by requiring you to use `c.file`.

---

## Comparison with Other Systems

### vs. Rust Borrow Checker

**Semantic**:
- Tracks resource states (open/closed)
- Field names = identity
- States transition through events

**Rust**:
- Tracks ownership (owned/borrowed/moved)
- Pointers = identity
- Ownership transfers through moves

### vs. Session Types

**Semantic**:
- Lighter weight
- Focus on resource lifecycle
- Invalidation on state change

**Session Types**:
- Protocol enforcement
- Typestate for communication
- Linear types (use exactly once)

---

*The semantic checker: Making resource leaks and use-after-close impossible at compile time.* 🛡️
