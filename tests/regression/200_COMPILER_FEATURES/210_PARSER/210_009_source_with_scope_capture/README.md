# Test 059: Source with Captured Scope

## The Goal

Implement **Phase 2: Scope Capture** for Source parameters.

When parser encounters a Source block, capture the lexical scope (constants, bindings) so template engines can interpolate variables.

## Example: HTML Template with Scope

```koru
const userName = "Alice";
const userAge = 42;

~renderHTML {
    <div>
        <h1>${userName}</h1>
        <p>You are ${userAge} years old</p>
    </div>
}
```

The parser should capture `userName` and `userAge` so the `renderHTML` proc can interpolate them.

## How It Works

When parser encounters a Source parameter block, it captures THREE things:

### 1. Text (Raw Source)
```koru
~renderHTML {
    <div>${userName}</div>
}
```
→ `text = "    <div>${userName}</div>\n"`

Can be ANY language - HTML, SQL, Lua, GLSL, whatever!

### 2. Location (For Error Messages)
```koru
// input.kz, line 45
~renderHTML {
    <div>${userName}</div>  // Line 46
}
```
→ `location = { .file = "input.kz", .line = 46, .column = 5 }`

Errors in template point to ORIGINAL source!

### 3. Scope (Lexical Capture) ← **THIS IS WHAT WE NEED TO IMPLEMENT**
```koru
const userName = "Alice";
const userAge = 42;

~renderHTML {
    <div>${userName}, ${userAge}</div>
}
```

→ `scope.bindings = [...]` (see AST Structure below)

## AST Structure

Parser needs to populate this structure (types already exist in `src/ast.zig`):

```zig
// In Arg.source_value
Source{
    .text = "    <div>\n        <h1>${userName}</h1>\n        <p>You are ${userAge} years old</p>\n    </div>\n",
    .location = .{
        .file = "input.kz",
        .line = 46,  // First line of Source block content
        .column = 5,
    },
    .scope = CapturedScope{
        .bindings = &[_]ScopeBinding{
            .{
                .name = "userName",
                .type = "[]const u8",
                .value_ref = "userName",
            },
            .{
                .name = "userAge",
                .type = "i32",
                .value_ref = "userAge",
            },
        },
    },
}
```

## What Phase 2 Needs to Capture

When parsing `~renderHTML { ... }`, the parser should:

1. **Walk the current scope** to find all visible bindings
2. **For each constant** (`const userName = ...`), create a `ScopeBinding`:
   - `name`: The constant name
   - `type`: The type (from type inference, or `"unknown"` for now)
   - `value_ref`: Same as name (for simple constants)
3. **Store bindings** in `Source.scope.bindings`

### Scope to Capture

**For this test, we need to capture:**
- `userName: []const u8` (string constant)
- `userAge: i32` (integer constant)

**Future phases will also capture:**
- Continuation bindings (`| result r |>` → capture `r` and `r.field`)
- Function parameters (if Source block is inside a proc)
- Other visible symbols

## Usage in Comptime Proc

```zig
~proc renderHTML {
    // 1. Access the raw source text
    std.debug.print("Text: {s}\n", .{source.text});

    // 2. See what variables are available in scope
    for (source.scope.bindings) |binding| {
        std.debug.print("Captured: {s}: {s} = {s}\n", .{
            binding.name,
            binding.type,
            binding.value_ref
        });
    }

    // 3. Phase 3 would: Parse HTML, find ${variable}, look up in scope.bindings
    // For now, just return placeholder
    return .{ .rendered = .{ .html = "<div>Hello!</div>" } };
}
```

## Implementation Status

### Phase 1: AST Types ✅ (Completed 2025-10-22)
- ✅ `Source` struct with text, location, scope
- ✅ `CapturedScope` struct with bindings
- ✅ `ScopeBinding` struct with name, type, value_ref
- ✅ `Arg.source_value` field for Source arguments
- ✅ All types compile successfully

**Files:**
- `src/ast.zig` - Source, CapturedScope, ScopeBinding types

### Phase 2: Parser Captures Scope 🚧 (THIS TEST)
**Goal**: When parser encounters Source block, capture visible constants

**What to capture (for this test):**
1. Module-level constants (`const userName = ...`, `const userAge = ...`)

**Future scope capture:**
2. Continuation bindings (`| result r |>` → capture `r` and fields)
3. Function parameters (if Source block is inside a proc)

**Parser changes needed:**
- In `parseImplicitSourceBlock()`: Collect visible bindings before parsing block
- Walk module-level items to find constants
- Create `ScopeBinding` for each constant
- Populate `Source.scope.bindings`

**Files to modify:**
- `src/parser.zig` - Add scope collection in `parseImplicitSourceBlock()`

### Phase 3: Template Interpolation (Future)
**Goal**: Parse templates and interpolate variables from scope

**Example:** HTML template proc that:
1. Parses HTML from `source.text`
2. Finds `${variable}` patterns
3. Looks up `variable` in `source.scope.bindings`
4. Generates Zig code: `try writer.print("{s}", .{userName});`

This is FUTURE WORK - not needed for Phase 2.

## Current Test Expectation

**When Phase 2 is complete:**
- ✅ Parser compiles the test without errors
- ✅ `source.text` contains the HTML template
- ✅ `source.location` points to line 46, column 5
- ✅ `source.scope.bindings.len == 2`
- ✅ Bindings include `userName` and `userAge`
- ✅ Proc prints captured bindings to stdout

**For now (without Phase 2):**
- ❌ Frontend compilation fails
- ❌ `source.scope.bindings` is empty (not populated yet)

## Related Tests

- **Test 055**: Source parameter syntax - ✅ PASSING (just syntax, no scope)
- **Test 059**: Source with scope - 🚧 THIS TEST (adds scope capture)

---

**Test Type**: Scope capture for metaprogramming
**Status**: Phase 1 complete ✅, Phase 2 in progress 🚧
**Impact**: Enables HTML templates, SQL queries, embedded DSLs with variable interpolation 🚀
