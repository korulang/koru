# Phantom Types Specification

> Compile-time tracking of runtime states through opaque type annotations.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-11-03
**Test Range**: 507-519, 909-920

---

## What Are Phantom Types?

**Phantom types** are compile-time annotations on types that track runtime states without affecting the actual type at runtime. They enable the compiler to enforce state machines, resource lifecycles, and other temporal properties.

```koru
~event open_file { path: []const u8 }
| opened { file: *File[fs:open!] }  // Phantom state: fs:open with cleanup required

~event close_file { file: *File[fs:open] }
| closed { file: *File[fs:closed] }

// This compiles:
~open_file(path: "test.txt")
| opened o |> close_file(file: o.file)
    | closed c |> _

// This fails at compile time:
~open_file(path: "test.txt")
| opened o |> close_file(file: o.file)
    | closed c |> close_file(file: c.file)  // ❌ Error: expects [fs:open], got [fs:closed]
```

---

## Phantom Type Syntax

### Basic States

```koru
*Type[state]           // Simple state
*Type[module:state]    // Module-qualified state
*Type[module:state!]   // Cleanup-required state (! suffix)
```

### State Variables (Generics)

```koru
*Type[M'owned|borrowed]    // State variable M constrained to owned OR borrowed
*Type[F'_]                 // State variable F with wildcard (any state)
```

### Multiple States (Union Types)

```koru
*Type[open|closing]        // Accepts either state
```

---

## Phantom Type Semantics

Phantom types are **opaque strings** - their meaning is determined by the **semantic checker** you use. Different checkers can interpret phantom types differently!

### 1. Semantic Checker (Default)

**Purpose**: Resource lifecycle tracking

**Identity Model**: `binding.field` names track resource identity through flows

**Key Features**:
- States transition through matching field names in event signatures
- Old bindings become invalidated when state changes
- Cleanup obligations (`!`) can be tracked (when implemented)

**Example**:
```koru
~event open { path: []const u8 }
| opened { file: *File[fs:open!] }

~event close { file: *File[fs:open] }
| closed { file: *File[fs:closed] }

// Identity tracking:
| opened f1 |>  // f1.file identity created with [fs:open!]
    close(f1.file)
    | closed c1 |>  // c1.file continues f1.file's identity, now [fs:closed]
        use(f1.file)  // ❌ SEMANTIC ERROR: f1.file invalidated, use c1.file
```

**Best For**:
- File handles
- Database connections
- GPU resources
- UI contexts
- Network sockets

See: [SEMANTIC.md](./SEMANTIC.md)

### 2. Rust-Style Borrow Checker (Planned)

**Purpose**: Ownership and borrowing enforcement

**Identity Model**: Actual pointer/reference tracking with lifetime annotations

**Key Features**:
- Ownership transfer detection
- Mutable vs immutable borrows
- Lifetime scoping
- Prevents aliasing violations

**Syntax**:
```koru
~event process<'a> { data: *Data['a:owned] }
| done { data: *Data['a:moved] }

~event borrow<'a> { data: *Data['a:owned] }
| borrowed { data: *Data['a:borrowed], original: *Data['a:lent] }
```

**Best For**:
- Memory safety
- Preventing use-after-free
- Concurrent access control

See: [BORROW_CHECKING.md](./BORROW_CHECKING.md) (planned)

### 3. ECS Component Tracking (Planned)

**Purpose**: Entity component system validation

**Identity Model**: Entity ID with component presence/absence tracking

**Key Features**:
- Component presence requirements
- Component addition/removal tracking
- System compatibility checking

**Syntax**:
```koru
~event render { entity: *Entity[has:transform+sprite+health] }
| rendered { entity: *Entity[has:transform+sprite+health] }

~event remove_sprite { entity: *Entity[has:sprite] }
| removed { entity: *Entity[lacks:sprite] }
```

**Best For**:
- Game engines
- Data-oriented designs
- Component systems

See: [ECS.md](./ECS.md) (planned)

### 4. Custom Semantic Checkers

You can write your own phantom type checker as a compiler pass!

```koru
~event my_phantom_checker { ast: FlowAST }
| valid { ast: FlowAST }
| invalid { errors: []Error }

~proc my_phantom_checker {
    // Implement YOUR domain-specific phantom semantics
    // Examples:
    // - HTTP state machines (idle → sending → waiting → receiving)
    // - GPU pipeline states (uninitialized → compiled → bound → executing)
    // - Transaction states (open → dirty → committed/rolled_back)
    // - Authentication states (unauthenticated → authenticated → authorized)
}
```

---

## The Semantic Checker (Default)

The default phantom type checker uses **field name identity tracking**.

### Identity Rule

Two bindings refer to the **same resource** if:
1. They have the same field name
2. One was derived from the other through event invocations

```koru
| opened f1 |>       // f1.file is identity "file-1"
    write(f1.file)
    | written w1 |>  // w1.file continues "file-1" (same field name "file")
        close(w1.file)
        | closed c1 |> // c1.file continues "file-1"
```

### Invalidation Rule

When a phantom state changes:
- The old binding becomes **invalidated**
- Must use the new binding from the continuation

```koru
| opened f |>
    close(f.file)    // f.file consumed here
    | closed c |>
        read(f.file)  // ❌ ERROR: f.file invalidated
        read(c.file)  // ✅ OK: c.file is current binding
```

### Multiple Resources

Different field names = different identities:

```koru
| opened o |>  // o.file1 and o.file2 are separate identities
    close(o.file1)
    | closed c |>
        read(o.file1)  // ❌ ERROR: file1 is closed
        read(o.file2)  // ✅ OK: file2 still open
```

---

## Cleanup Obligations (!)

The `!` marker provides compile-time enforcement of resource cleanup through two complementary syntaxes:

### Producing Obligations: `[state!]`

The `!` suffix on a **return signature** marks states that **require cleanup** before going out of scope:

```koru
~event open { path: []const u8 }
| opened { file: *File[opened!] }  // ! produces cleanup obligation

~open(path: "test.txt")
| opened f |>
    _  // ❌ ERROR: f.file has cleanup obligation that must be satisfied!
```

### Consuming Obligations: `[!state]`

The `!` prefix on a **parameter** marks events that **dispose** of resources:

```koru
~event close { file: *File[!opened] }  // ! consumes cleanup obligation
| closed {}

~open(path: "test.txt")
| opened f |> close(file: f.file)  // Obligation satisfied by disposal
    | closed |>
        _  // ✅ OK: f.file was properly cleaned up
```

### Escaping Through Interfaces

Obligations can be **documented as escaping** through return signatures:

```koru
~event my_subflow {}
| file_opened { file: *File[opened!] }  // ! in return = documented escape

~proc my_subflow {
    ~open(path: "internal.txt")
    | opened f |> file_opened { file: f.file }
    // No error! Obligation escapes through signature
}

// Caller receives the obligation:
~my_subflow()
| file_opened f |> close(file: f.file)  // Caller's responsibility
    | closed |> _
```

### Safety Model: Trust Library Authors, Verify Usage

Koru's cleanup obligation system follows a **pragmatic safety model**:

**The compiler CANNOT verify** that a disposal event (`[!state]`) actually cleans up the resource. This is the **library author's responsibility**:
```koru
~event file.close { file: *File[!opened] }
| closed {}

~proc close {
    // Library author's responsibility: actually close the file!
    c.fclose(file.handle);
    return .{ .closed = .{} };
}
```

**The compiler CAN verify** that library users properly handle cleanup obligations:
```koru
~open(path: "test.txt")
| opened f |>
    _  // ❌ Compile error: forgot to close

~open(path: "test.txt")
| opened f |> close(file: f.file)
    | closed |> _  // ✅ OK: properly cleaned up

~open(path: "test.txt")
| opened f |> close(file: f.file)
    | closed |> use_file(file: f.file)  // ❌ Error: use after disposal!
```

This is **lower safety than Rust** (which proves library correctness) but **higher safety than most languages** (which have no compile-time cleanup enforcement). The trade-off enables:
- C interop without lies
- Narrative engine flexibility
- Performance without runtime overhead
- Extensibility through custom compiler passes

**Best practice**: Library correctness is verified through testing. Usage correctness is verified by the compiler.

### Cleanup Semantics: Bindings Persist

Unlike Rust, Koru bindings **do not move** when passed to events. They **persist** through nested continuations:

```koru
~open(path: "test.txt")
| opened f |> store(file: f.file)
    | stored |>
        use(file: f.file)  // ✅ OK: f.file is STILL accessible
        | used |> _  // ❌ ERROR: still has cleanup obligation!
```

Cleanup obligations are only satisfied when:
1. Resource passed to disposal event (`[!state]`), OR
2. Resource returned with `!` in continuation signature (documented escape)

After disposal, the binding becomes **poisoned** and cannot be used:
```koru
| opened f |> close(file: f.file)  // Disposes f.file
    | closed |>
        use(file: f.file)  // ❌ ERROR: f.file was disposed!
```

**Status**: Implementation in progress (tests 513-519)

See: [CLEANUP_SEMANTICS.md](./CLEANUP_SEMANTICS.md) for detailed examples

---

## Module-Qualified States

Phantom states can be qualified by module to avoid collisions:

```koru
*File[fs:open]         // Filesystem module's "open" state
*Buffer[gpu:allocated] // GPU module's "allocated" state
*Conn[http:idle]       // HTTP module's "idle" state
```

This allows different modules to use the same state names (`open`, `closed`) without conflict.

See: [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/)

---

## Design Principles

### 1. Phantom Types Are Optional

You can use Koru without phantom types! They're an **ergonomic aid**, not a requirement.

```koru
// Without phantom types - works fine
~event open {}
| opened { file: *File }

// With phantom types - compiler helps prevent mistakes
~event open {}
| opened { file: *File[fs:open!] }
```

### 2. Phantom Semantics Are Pluggable

The meaning of phantom types is determined by the semantic checker, which is **user-replaceable**.

Don't like the default semantic checker? Write your own! Or use multiple checkers in your compilation pipeline.

### 3. Zero Runtime Cost

Phantom types are **compile-time only**. They generate the same code as non-phantom types.

```koru
*File[fs:open]  // Compiles to: std.fs.File
```

The phantom annotation `[fs:open]` exists only during compilation.

---

## Verified By Tests

**Semantic Checker**:
- [909_phantom_state_mismatch](../909_phantom_state_mismatch/) - Detects incompatible states
- [910_phantom_state_valid](../910_phantom_state_valid/) - Accepts valid transitions
- [507_module_qualified_phantom_states](../507_module_qualified_phantom_states/) - Module-qualified states

**Cleanup Obligations**:
- [513_cleanup_obligation_escape](../513_cleanup_obligation_escape/) - Error on uncleaned resources at terminator
- [514_cleanup_obligation_satisfied](../514_cleanup_obligation_satisfied/) - Proper cleanup with `[!state]` disposal
- [515_cleanup_consumed_by_disposal](../515_cleanup_consumed_by_disposal/) - Disposal event consumes obligation
- [516_use_after_disposal](../516_use_after_disposal/) - Error on use after disposal
- [517_obligation_escapes_via_interface](../517_obligation_escapes_via_interface/) - Obligation transfers through return signature
- [518_obligation_lost_at_boundary](../518_obligation_lost_at_boundary/) - Error when obligation lost at flow boundary
- [519_multiple_cleanup_paths](../519_multiple_cleanup_paths/) - Multiple disposal events coexist

**Planned**:
- Identity tracking through field names
- Multiple resource tracking
- Borrow checking semantics
- ECS component semantics

---

## Related Specifications

- [Validation](../400_VALIDATION/SPEC.md) - Type checking, coverage checking
- [Compiler Architecture](../../../docs/architecture/COMPILER_ARCHITECTURE.md) - Semantic checker integration

---

*Phantom types: Making impossible states unrepresentable, one compile at a time.* ✨
