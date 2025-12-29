# Test 109: renderHTML Actually Working (Integration Test)

## Status: DESIGN INTENT CAPTURED

**Dependencies**: Tests 105, 106, 107
**Implementation**: Multi-phase (MVP → Full interpolation → Optimization)

## What This Test Proves

This is the **CROWN JEWEL** test - it proves the entire metaprogramming vision works end-to-end:

```koru
~getUserData
| data u |> renderHTML [HTML]{
    <h1>${u.name}</h1>
    <p>Age: ${u.age}</p>
} | rendered h |> std.io:println(text: h.html)
```

**Expected output**:
```html
<h1>Alice</h1>
<p>Age: 42</p>
```

## The Complete Flow

### Step 1: Parser (Test 105 ✅)
```
Parser sees: | data u |> renderHTML [HTML]{ ... }
Captures: source.scope.bindings = [{ name: "u", type: "...", value_ref: "u" }]
Creates: AST with source_value containing bindings
```

### Step 2: evaluate_comptime Detects (Tests 106-107)
```
Pass finds: renderHTML is comptime (has Source parameter)
Extracts: The Item (flow node) containing this invocation
Prepares: Call to renderHTML proc with item, program_ast, allocator
```

### Step 3: renderHTML Executes (THIS TEST!)
```zig
~proc renderHTML {
    // 1. Parse source.text: "<h1>${u.name}</h1><p>Age: ${u.age}</p>"
    //    Finds interpolations: ["u.name", "u.age"]

    // 2. Look up in source.scope.bindings:
    //    "u" → {name: "u", type: "{ name: []const u8, age: i32 }", value_ref: "u"}

    // 3. Validate: u.name and u.age are accessible from binding

    // 4. Generate runtime Zig code:
    const generated_code =
        \\const html = try std.fmt.allocPrint(allocator,
        \\    "<h1>{s}</h1><p>Age: {d}</p>",
        \\    .{u.name, u.age}
        \\);

    // 5. Transform the Item:
    //    Replace renderHTML invocation with generated formatting code
    //    Return new flow that produces | rendered { html: []const u8 }

    return .{ .transformed = .{ .item = transformed_flow } };
}
```

### Step 4: AST Replacement
```
evaluate_comptime receives: transformed Item
Replaces: Original flow with transformed flow
Result: AST now contains runtime code, no comptime invocations
```

### Step 5: Runtime Execution
```
Generated code runs:
- Formats HTML with u.name="Alice" and u.age=42
- Returns "<h1>Alice</h1><p>Age: 42</p>"
- Prints output
```

## Implementation Strategy

### Phase 1: MVP (Hardcoded Transform)
**Goal**: Prove the plumbing works

```zig
~proc renderHTML {
    // Return hardcoded HTML just to prove transformation works
    const html = "<h1>Alice</h1><p>Age: 42</p>";

    // Transform item to return this hardcoded string
    // (Proves Item transformation mechanism works)

    return .{ .transformed = .{ .item = transformed_item } };
}
```

**Success criteria**: Compiles, runs, outputs HTML

### Phase 2: Basic Interpolation
**Goal**: Parse ${...} and generate std.fmt.allocPrint

```zig
~proc renderHTML {
    // 1. Parse source.text for ${...} patterns
    const interpolations = try parseInterpolations(allocator, source.text);

    // 2. For each interpolation, look up in source.scope.bindings
    for (interpolations) |interp| {
        const binding = findBinding(source.scope.bindings, interp.var_name);
        // Validate binding exists and has right type
    }

    // 3. Generate std.fmt.allocPrint call
    const format_str = replaceInterpolationsWithSpecifiers(source.text, interpolations);
    const format_args = buildFormatArgs(interpolations, bindings);

    // 4. Create AST nodes for the generated code
    const generated_code = try generateFormattingCode(allocator, format_str, format_args);

    // 5. Transform Item to contain generated code
    const transformed = try transformItemWithCode(allocator, item, generated_code);

    return .{ .transformed = .{ .item = transformed } };
}
```

**Success criteria**: ${u.name} and ${u.age} interpolate correctly

### Phase 3: Advanced Features
- **Nested field access**: `${u.address.city}`
- **Method calls**: `${u.name.toUpper()}`
- **Expressions**: `${u.age * 2}`
- **Conditionals**: `${if u.age >= 18 "adult" else "minor"}`
- **Loops**: `${for item in u.items}...${end}`

## Key Helper Functions

### parseInterpolations
```zig
fn parseInterpolations(allocator: std.mem.Allocator, text: []const u8) ![]Interpolation {
    // Scan for ${...} patterns
    // Return list of { start: usize, end: usize, expr: []const u8 }
}
```

### findBinding
```zig
fn findBinding(bindings: []const ScopeBinding, var_name: []const u8) ?ScopeBinding {
    // Look up variable in captured scope
    // Handle dotted access: "u.name" → find "u", check field "name"
}
```

### generateFormattingCode
```zig
fn generateFormattingCode(
    allocator: std.mem.Allocator,
    format_str: []const u8,
    format_args: []FormatArg
) ![]const u8 {
    // Generate:
    // const html = try std.fmt.allocPrint(allocator, "format_str", .{args...});
}
```

### transformItemWithCode
```zig
fn transformItemWithCode(
    allocator: std.mem.Allocator,
    item: *const Item,
    generated_code: []const u8
) !Item {
    // Create new flow that:
    // 1. Executes generated_code
    // 2. Returns result in | rendered { html: []const u8 }

    // Uses ast_functional.zig to build AST nodes
}
```

## What This Enables

Once this test passes, you can write:

### React-style Components
```koru
~event Card {
    source: Source[HTML],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }

// Usage:
~getUserData
| data u |> Card [HTML]{
    <div class="card">
        <h2>${u.title}</h2>
        <p>${u.description}</p>
    </div>
} | rendered c |> sendHTTP(body: c.html)
```

### SQL Query Builders
```koru
~event buildQuery {
    source: Source[SQL],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }

// Usage:
~getUser
| user u |> buildQuery [SQL]{
    SELECT * FROM posts
    WHERE author_id = ${u.id}
    AND created_at > ${u.since}
} | query q |> db.execute(sql: q.text)
```

### Configuration DSLs
```koru
~event parseConfig {
    source: Source[TOML],
    item: *const Item,
    program_ast: *const ProgramAST,
    allocator: std.mem.Allocator
}
| transformed { item: Item }

// Usage:
~parseConfig [TOML]{
    [server]
    host = "${env.HOST}"
    port = ${env.PORT}
} | config c |> startServer(config: c)
```

## Why This Is Revolutionary

This combines:
- ✅ **Type safety** - All variables checked at compile time
- ✅ **Scope capture** - Lexical bindings preserved
- ✅ **Zero runtime overhead** - Generates efficient code
- ✅ **Composability** - Templates are just events
- ✅ **Inspectability** - AST transformations are explicit

**No other language has all of these simultaneously!**

Rust proc macros: Not scope-aware, complex
TypeScript template literals: Runtime, not compile-time optimized
Zig comptime: Powerful but no scope capture
Lisp macros: Powerful but dynamically typed

**Koru**: All of the above, typed, safe, inspectable!

## Success Metrics

**Phase 1 MVP**: ✅ Hardcoded output proves plumbing
**Phase 2 Basic**: ✅ ${u.name} and ${u.age} interpolate
**Phase 3 Advanced**: ✅ Nested access, expressions, control flow

When Phase 2 works, this test becomes a **PASSING REGRESSION TEST** that proves Koru is a real metaprogramming language!
