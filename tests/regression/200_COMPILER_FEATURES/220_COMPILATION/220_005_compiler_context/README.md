# Test 630: CompilerContext via Service Locator

Documents obtaining **CompilerContext** through service locator pattern (not DI injection).

## Overview

CompilerContext is a **service** obtained explicitly via `~std.compiler:get_compiler_context()`. This is different from syntax constructs (FlowAST, Source, Expression) which are implicit.

## CompilerContext API

### Error Reporting

**ctx.error(message, location)**
- Reports a compilation error
- Increments error count
- May abort compilation depending on error policy

```koru
ctx.error(
    message: "Invalid syntax",
    location: item.source_location
);
```

**ctx.warning(message, location)**
- Reports a warning
- Does NOT increment error count
- Never aborts compilation

```koru
ctx.warning(
    message: "Deprecated API usage",
    location: @source_location()
);
```

**ctx.info(message)**
- Informational message
- For verbose/debug output
- Controlled by verbosity flags

```koru
ctx.info(message: "Processing 42 items");
```

### Error Policy

**ctx.should_abort() -> bool**
- Returns true if compilation should stop after current error
- Controlled by compiler flags (--strict, --continue-on-error)

```koru
if (ctx.should_abort()) {
    return .{ .invalid = .{} };
}
```

**Default policies:**
- Normal mode: Continue collecting errors
- Strict mode (`--strict`): Abort on first error

### Metrics & State

**ctx.begin_pass(name)**
- Marks beginning of a compilation pass
- Used for timing and profiling
- Increments pass counter

```koru
ctx.begin_pass("collect_build_requirements");
```

**ctx.end_pass(name)**
- Marks end of a compilation pass
- Must match corresponding begin_pass

```koru
ctx.end_pass("collect_build_requirements");
```

**ctx.pass_count() -> u32**
- Returns current pass number
- Increments with each begin_pass/end_pass pair

```koru
const pass = ctx.pass_count();
```

**ctx.error_count() -> u32**
- Returns total errors reported so far
- Useful for deciding whether to continue

```koru
if (ctx.error_count() > 0) {
    // Skip optimization if there are errors
}
```

**ctx.warning_count() -> u32**
- Returns total warnings reported

## Usage Patterns

### Validator Pattern

```koru
~proc validate {
    ctx.begin_pass("validation");

    if (invalid_data) {
        ctx.error(
            message: "Data validation failed",
            location: @source_location()
        );

        if (ctx.should_abort()) {
            ctx.end_pass("validation");
            return .{ .invalid = .{} };
        }
    }

    ctx.end_pass("validation");
    return .{ .valid = .{} };
}
```

### Collector Pattern (Continue on Error)

```koru
~proc collect {
    ctx.begin_pass("collection");

    for (ast.items) |item| {
        if (error_in_item) {
            ctx.error(
                message: "Item error",
                location: item.location
            );

            // Continue collecting to find ALL errors
            if (!ctx.should_abort()) {
                continue;
            } else {
                break;
            }
        }

        collect_item(item);
    }

    ctx.end_pass("collection");
}
```

### Conditional Processing Pattern

```koru
~proc optimize {
    // Skip optimization if there are errors
    if (ctx.error_count() > 0) {
        ctx.info(message: "Skipping optimization due to errors");
        return;
    }

    ctx.begin_pass("optimization");
    // ... perform optimization ...
    ctx.end_pass("optimization");
}
```

## Service Locator Pattern

CompilerContext is obtained through **explicit service locator calls**, not DI injection.

### Syntax Constructs (Implicit)

These are **syntax transformations**, handled by the compiler:
- `FlowAST` - From `{ flow }` blocks
- `Source` - From `{ source }` blocks
- `Expression` - First positional parameter syntax

### Services (Explicit via Service Locator)

These are **obtained explicitly** through service calls:
- `CompilerContext` - Via `~std.compiler:get_compiler_context()`
- User-defined services - Via custom service locators

### The Pattern

**Subflow with service locator:**
```koru
~collect =
    std.compiler:get_compiler_context()
    | compiler_context ctx |> std.compiler:begin_pass(ctx, name: "collection")
        | compiler_pass pass |> collection_work(ctx, pass)
            | succeeded |> std.compiler:end_pass(ctx, pass)
                | compiler_pass _ |> done {}
```

**Dependencies visible in FlowAST:**
- You SEE the `get_compiler_context()` call
- Flow explicitly shows acquisition
- Statically analyzable
- Mockable via flow substitution

## Compiler Flags

**--strict**
- Sets error policy to abort on first error
- `ctx.should_abort()` returns true after ANY error

**--continue-on-error** (default)
- Collects all errors before aborting
- Allows comptime handlers to report multiple errors

**--verbose** / **-v**
- Enables `ctx.info()` output
- Shows pass timing and metrics

## Testing with Flow Substitution

The service locator pattern enables natural testing through **flow substitution** (not yet implemented).

### Mocking Services

```koru
~test(name: "Validation with mock context") {
    // Substitute the service locator in this test's FlowAST
    ~std.compiler:get_compiler_context = compiler_context { ctx: MockContext }

    // Now when validate runs, it gets MockContext
    ~validate(data: "test data")
    | valid |> assert_success()
    | invalid |> assert_failure()
}
```

### Event Purity Observable

**Mock coverage reveals test type:**
- More mocks = unit test (pure, isolated from services)
- Fewer mocks = integration test (uses real services)
- **FlowAST analysis can measure purity!**

This makes event purity an **observable property** from the test's FlowAST.

## Why Service Locator (Not Anti-Pattern Here)

Service locator is typically an anti-pattern because:
- ❌ Hidden dependencies (where does `getLogger()` come from?)
- ❌ Hard to mock (global registry, threading issues)
- ❌ Untestable

**In Koru, these concerns don't apply:**
- ✅ Dependencies visible in FlowAST (you see the call)
- ✅ Mockable via flow substitution (thread-safe by design)
- ✅ Statically analyzable (FlowAST shows all acquisitions)

The flow IS the documentation of dependencies!

## Implementation Status

- ❌ CompilerContext type definition
- ❌ Service locator implementation (`std.compiler:get_compiler_context()`)
- ❌ Error/warning/info reporting infrastructure
- ❌ Pass tracking (begin_pass, end_pass, CompilerPass type)
- ❌ Error policy support (--strict, --continue-on-error)
- ❌ Flow substitution for testing

This test **documents the intended API** before implementation.

## Design Goals

1. **Uniform error reporting** - All comptime code uses same mechanism
2. **Flexible error policies** - User controls abort vs continue
3. **Observable compilation** - Pass metrics and timing
4. **Clean API** - Implicit availability, simple calls
5. **Production-ready** - Support for both strict and lenient modes

## Related Tests

- [619_build_requires_basic](../619_build_requires_basic/) - Uses ctx for build requirement validation
- [600_COMPTIME/SPEC.md](../SPEC.md) - Top-level comptime execution
