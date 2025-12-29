# Compile-Time Metaprogramming Specification

> FlowAST, ProgramAST, Expression - code generation and transformation at compile-time.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-05
**Test Range**: 701-709

---

## Overview

Koru supports powerful compile-time metaprogramming through special types that allow code to manipulate and transform other code:

- **Expression** - Pass expressions as data for control flow and evaluation
- **FlowAST** - Pass flows as data for transformation
- **ProgramAST** - Access entire program for global transformations
- **Source** - Pass arbitrary syntax as data
- **File** - Compile-time file reading (not embedded)
- **EmbedFile** - Runtime file embedding (embedded in binary)

All special types enable compile-time processing in procs marked with `~[comptime]`.

---

## Expression Type

Pass expressions as compile-time data for control flow and computation.

### Basic Syntax

```koru
~pub event if { expr: Expression }
| true {}
| ?false {}

~pub event expr { expr: Expression }
| result { value: <inferred_at_comptime> }
```

### Expression Parameter Rules

1. **First positional implicit**: First `Expression` parameter can be positional (no name needed)
2. **Others must be named**: Additional `Expression` parameters must use `name: expr` syntax
3. **Proc-only invocation**: Events with `Expression` parameters can only be invoked from proc inline flows
4. **Comptime evaluation**: Expression AST passed to comptime proc for code generation

### Usage Examples

**Conditional branching**:
```koru
~proc handle {
    // if - single implicit Expression
    ~if(age >= 18)
    | true |> serve_alcohol()
    | false |> serve_juice()
}
```

**Expression evaluation**:
```koru
~proc process {
    // expr - evaluate and branch on result
    ~expr(calculate_score(data))
    | result r when r.value > 100 |> excellent()
    | result r when r.value > 50 |> good()
    | result r |> needs_improvement()  // Catch-all required!
}
```

**Loop with condition**:
```koru
~pub event while { expr: Expression, max_iters: ?u32, flow: FlowAST }
| done {}

~proc loop {
    ~while(count < max, max_iters: 1000) {
        ~increment()
        | updated u |> count = u.value
    }
    | done |> finish()
}
```

### Implementation

```koru
~[comptime]proc if {
    // At compile time:
    const expr_ast = expr;  // Expression parse tree

    // Emit: if (expr) { true_branch } else { false_branch }
    // Branches determined by continuations
}

~[comptime]proc expr {
    const expr_ast = expr;
    const return_type = inferType(expr_ast);  // Infer from context

    // Generate branch with inferred type
    // Emit evaluation code
}
```

### Allowed Operations

- ✅ Field access: `obj.field`, `obj.nested.field`
- ✅ Comparisons: `==`, `!=`, `<`, `>`, `<=`, `>=`
- ✅ Logical: `&&`, `||`, `!`
- ✅ Literals: numbers, strings, booleans
- ✅ Arithmetic (in procs): `+`, `-`, `*`, `/`
- ❌ Function calls (in pure flows): `getValue()`

---

## FlowAST Type

Pass Koru flows as data for compile-time transformation.

### Basic Syntax

```koru
~event transform { transform_flow: FlowAST }
| done { result: any }

~transform {
    transform_flow: {
        fetch(id: 123)
        | found f |> process(f.data)
        | missing |> use.default()
    }
}
| done d |> _
```

### Implicit FlowAST Parameter

When an event has a `FlowAST` parameter, you can provide it implicitly using `{}` blocks:

```koru
// Event with flow parameter
~pub event optimize { cache_key: []const u8, flow: FlowAST }

// Implicit syntax - using {} directly after invocation
~optimize(cache_key: "v1") {
    ~fetch(id: 123)                // ~ marks each flow in the FlowAST
    | found f |> process(f.data)   // Must be exhaustive
    | missing |> use.default()      // Completes this flow

    ~validate(data)                 // New flow starts (also with ~)
    | valid v |> store(v)
    | invalid |> reject()
}
| optimized o |> log(o.stats)      // Outside {} = optimize's output branch
| unchanged |> use_original()
```

### Key Rules for Implicit FlowAST

1. Use `{}` after the invocation to provide implicit FlowAST content
2. Each flow within the `{}` MUST start with `~` (just like top-level flows in a file)
3. Each flow must be exhaustive (all branches handled)
4. The `{}` creates a mini Koru environment where `~` marks flows
5. Continuations outside `{}` handle the event's output branches

### Implementation

This enables transparent metaprogramming where the proc receives flows as data:

```koru
~proc optimize {
    comptime {
        const flows = flow;         // Array of flows from the FlowAST
        const key = cache_key;

        // Analyze and transform flows
        if (canOptimize(flows)) {
            // Generate optimized code with new branches
            return generateOptimized(flows);
        } else {
            // Generate unchanged branch
            return generatePassthrough(flows);
        }
    }
}
```

---

## ProgramAST Type

Access to the entire program's AST for global transformations.

### Basic Syntax

```koru
~event global_optimizer { ast: ProgramAST }
| optimized { ast: ProgramAST }

~proc global_optimizer {
    comptime {
        var new_ast = ast;

        // Global dead code elimination
        new_ast = eliminateUnusedEvents(new_ast);

        // Cross-event inlining
        new_ast = inlineAcrossEvents(new_ast);

        // Whole-program optimization
        new_ast = optimizeGlobally(new_ast);

        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

### With FlowAST

Events can accept both `FlowAST` and `ProgramAST` parameters:

```koru
// Event with both FlowAST and ProgramAST
~pub event optimize { flow: FlowAST, ast: ProgramAST }
| optimized { ast: ProgramAST }

// Usage - ProgramAST provided automatically
~optimize
| compute c |> process(c)         // Continuation → flow parameter
| done |> _                       // ProgramAST → current program

// The proc sees both the flow AND the entire program
~proc optimize {
    comptime {
        const flow_ast = flow;     // The continuation branches
        const program_ast = ast;   // The ENTIRE program!

        // Can analyze the local flow
        const patterns = analyzeFlow(flow_ast);

        // But transform the WHOLE program
        var new_ast = program_ast;
        new_ast = optimizeBasedOnPatterns(new_ast, patterns);

        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

### Use Cases

ProgramAST enables:
- Cross-event optimization
- Global dead code elimination
- Whole-program transformations
- Domain-specific compilation strategies

### Local Syntax, Global Effect

```koru
// Local invocation
~with_borrow_checking
| buffer b |> use(b)
| done |> _

// Global effect
~proc with_borrow_checking {
    comptime {
        // Add borrow checking to ALL buffers in the program!
        const new_ast = addGlobalBorrowChecking(ast, flow);
        return .{ .optimized = .{ .ast = new_ast } };
    }
}
```

---

## Source Type

Pass arbitrary syntax as data.

### Syntax

```koru
~event query { sql: Source, params: []any }
| rows { data: []Row }

~query {
    sql: {
        SELECT * FROM users
        WHERE age > ? AND city = ?
    },
    params: .{21, "NYC"}
}
| rows r |> display(r.data)
```

Use for embedded DSLs, SQL queries, configuration syntax, etc.

### Implicit Source Blocks

Like FlowAST, Source parameters can be provided implicitly using `{ }` blocks:

```koru
// Event with Source parameter
~pub event build_requires { source: Source }

// Implicit syntax - using {} directly
~build_requires {
    exe.linkSystemLibrary("sqlite3");
    exe.linkSystemLibrary("zlib");
}
```

The `{ }` block is compiled to a Source parameter containing the raw syntax.

---

## Top-Level Comptime Execution

Koru treats compile-time and runtime execution **symmetrically**:
- Runtime: Top-level calls collected into `main()`
- Comptime: Top-level calls executed during compilation

### Execution Model

**Runtime example:**
```koru
~hello()  // Top-level call
| done |> ~goodbye()
    | done |> _
```
Compiler collects these into `main()` function.

**Comptime example:**
```koru
~[comptime]build:collect(path: "build.zig")  // Top-level call
```
Compiler executes this during compilation.

### Automatic Execution on Import

Top-level comptime calls in imported modules execute automatically:

```koru
// In koru_std/build.kz
~[comptime]

~pub event collect { ast: ProgramAST }
~proc collect {
    // Walk AST, collect build requirements, write file
}

// Top-level call - executes when module is imported!
~[comptime(optional)]collect(path: "build.zig")
```

**User code:**
```koru
~[comptime]import "$std/build"  // This triggers collect()!

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

### Optional Execution

The `~[comptime(optional)]` annotation controls **automatic execution**, not availability.

**Default behavior:**
```koru
~[comptime(optional)]collect(path: "build.zig")
```
Executes automatically during compilation.

**With --disable flag:**
```bash
koruc input.kz --disable=std.build:collect
```

**What this does:**
- Skips automatic execution of this specific top-level call
- Event and proc remain in AST and compiled code
- User code can still call it manually

**Example - Custom orchestration:**
```koru
~[comptime]import "$std/build"

~[comptime]proc custom_build {
    // Manually invoke with custom parameters
    ~std.build:collect(path: "custom.zig")
    | done |> _
}

~[comptime]custom_build()
```

This enables **composability** - users can build on top of standard modules by disabling automatic behavior and orchestrating manually.

### Compiler-Provided Parameters

Comptime events **explicitly declare** which compiler-provided parameters they need.

**User declares what they need:**
```koru
~[comptime]
~pub event collect { ctx: CompilerContext, ast: ProgramAST, path: []const u8 }
```

**Compiler provides declared parameters:**
- `CompilerContext` - Provided by compiler
- `ProgramAST` - Provided by compiler
- `path` - Provided by user at call site

**Call site:**
```koru
~[comptime]collect(path: "build.zig")
```

**Compiler execution:**
```koru
collect(ctx: compiler_context, ast: program_ast, path: "build.zig")
```

This is **explicit and extensible** - you only get what you ask for.

### Complete Example: Build System

**In build.kz:**
```koru
~[comptime]

var requirements: std.ArrayList([]const u8) = undefined;

~pub event requires { source: Source }
~proc requires {
    // Validate and return for collection
    return .{ .added = .{ source = source } };
}

~pub event collect { ctx: CompilerContext, ast: ProgramAST }
~proc collect {
    // ctx and ast explicitly declared, compiler provides them
    ctx.begin_pass("collect_build_requirements");

    // Walk AST, find all build:requires
    for (ast.items) |item| {
        if (item.event == "std.build:requires") {
            // Extract Source parameter from AST node
            const source = item.params.source;

            // Call handler directly - it's just a function!
            const result = requires_event.handler(.{ .source = source });

            // Collect result
            if (result.added) {
                requirements.append(source);
            } else if (result.parse_error) {
                ctx.error(
                    message: result.parse_error.msg,
                    location: item.source_location
                );
            }
        }
    }

    ctx.end_pass("collect_build_requirements");
    write_build_zig(path, requirements);
}

// Executes automatically on import
~[comptime(optional)]collect(path: "build.zig")
```

**In user code:**
```koru
~[comptime]import "$std/build"  // Triggers collection

~[comptime]build:requires {
    exe.linkSystemLibrary("sqlite3");
}
```

### Use Cases

This pattern enables:
- **Build systems** - collect dependencies, generate build files
- **Optimizers** - transform AST, apply optimizations
- **Code generators** - derive serialization, generate boilerplate
- **Feature flags** - configure compilation behavior

See: [619_build_requires_basic](../619_build_requires_basic/BUILD_SYSTEM_DESIGN.md)

---

## File vs EmbedFile

### File (Compile-Time Only)

For compile-time file reading (contents NOT embedded in binary):

```koru
~event transpiler { source: File }
| transpiled { code: []const u8 }

~transpiler(source: "game.nes")
| transpiled t |> save(t.code)
```

The file is read during compilation but not embedded in the final binary.
Use for build-time operations, transpilation sources, configuration processing.

### EmbedFile (Runtime Embedded)

For runtime file embedding (contents embedded in binary):

```koru
~event assets { icon: EmbedFile }
| loaded { data: []const u8 }

~assets(icon: "logo.png")
| loaded l |> display(l.data)
```

The file's contents are embedded in the binary and available at runtime.
Use for assets, default configs, templates needed when the program runs.

---

## Compile-Time Events

Events with `FlowAST` or `ProgramAST` parameters can generate their branches at compile-time:

```koru
// Branches not declared - generated by proc!
~event optimize { cache_key: []const u8, flow: FlowAST }

~proc optimize {
    comptime {
        // Analyze flow and generate appropriate branches
        if (canOptimize(flow)) {
            return generateBranches(&[_]Branch{
                .{ .name = "optimized", .payload = .{ .stats = Stats } },
                .{ .name = "unchanged" },
            });
        } else {
            return generateBranches(&[_]Branch{
                .{ .name = "failed", .payload = .{ .reason = []const u8 } },
            });
        }
    }
}
```

**Execution order**:
1. Input shape is declared normally
2. Output branches are generated by the proc's `comptime` block
3. Shape checking happens after compile-time execution
4. Continuations are parsed optimistically and validated later

---

## Host Type Injection

Events can request type information from the host environment:

```koru
~event get_platform {}
| platform { os: HostType, arch: HostType }

~proc get_platform {
    comptime {
        const os = @import("builtin").os.tag;
        const arch = @import("builtin").cpu.arch;
        // Return platform info as branch
    }
}
```

See: [701_host_type_injection](../701_host_type_injection/)

---

## Benchmark Type

Performance testing as a first-class language feature using FlowAST:

```koru
~pub event benchmark {
    name: []const u8,
    iterations: u32,
    flow: FlowAST,
    warmup_iterations: ?u32
}
| results {
    name: []const u8,
    comparisons: []Comparison
}

pub const Comparison = struct {
    label: []const u8,           // Event name
    avg_ns: u64,                 // Average nanoseconds per iteration
    median_ns: u64,              // Median time
    min_ns: u64,                 // Minimum time
    max_ns: u64,                 // Maximum time
    std_dev: f64,                // Standard deviation
    vs_baseline_percent: ?f64    // Percent vs first entry
};
```

**Usage**:
```koru
~benchmark(name: "Event Dispatch Overhead", iterations: 1_000_000) {
    ~calculate_pure()
    | done |> _

    ~calculate_events()
    | done |> _
}
| results r |> print_results(r)
| results r |> assert_overhead_under(r, max_percent: 5.0)
```

---

## Design Rationale

**Why special types?**
- Enable metaprogramming without runtime cost
- Keep syntax clean and familiar
- Make code generation explicit
- Allow domain-specific optimizations

**Why compile-time only?**
- Zero runtime overhead
- Statically analyzable
- Deterministic code generation
- No reflection needed

**Why ProgramAST in addition to FlowAST?**
- Enable whole-program optimizations
- Support cross-event transformations
- Allow global analysis
- Domain-specific compilation

---

## Verified By Tests

- [619_build_requires_basic](../619_build_requires_basic/) - Metacircular execution, implicit Source blocks, multi-pass architecture
- [701_host_type_injection](../701_host_type_injection/) - Host environment types

---

## Related Specifications

- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - Event basics
- [Core Language - Proc Implementation](../000_CORE_LANGUAGE/SPEC.md#proc-implementation) - Comptime procs
- [Validation - Shape Rules](../400_VALIDATION/SPEC.md#shape-rules) - Type checking
- [Control Flow - When Clauses](../100_CONTROL_FLOW/SPEC.md#when-clauses) - Expression evaluation
