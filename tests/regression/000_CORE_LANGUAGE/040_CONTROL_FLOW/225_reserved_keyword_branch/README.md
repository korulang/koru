# Test 825: Reserved Zig Keyword as Branch Name

## The Bug

When a branch name is a Zig reserved keyword (like `error`, `return`, `const`, etc.), the emitter generates invalid Zig code that won't compile.

## Reproduction

```koru
~pub event process_file { path: []const u8 }
| success { data: []const u8 }
| error { msg: []const u8 }  // "error" is reserved in Zig!
```

## Expected Behavior

The parser should accept `error` as a valid branch name (it's a valid identifier in Koru). The emitter should escape it when generating Zig code:

```zig
pub const Output = union(enum) {
    success: struct { data: []const u8 },
    @"error": struct { msg: []const u8 },  // Escaped!
};

return .{ .@"error" = .{ .msg = "..." } };  // Escaped!

switch (result) {
    .@"error" => |e| { ... },  // Escaped!
    .success => |s| { ... },
}
```

## Actual Behavior

The emitter generates unescaped code:

```zig
pub const Output = union(enum) {
    success: struct { data: []const u8 },
    error: struct { msg: []const u8 },  // SYNTAX ERROR!
};
```

This fails Zig compilation because `error` is a reserved keyword.

## Zig Reserved Keywords

The emitter needs to escape these keywords when used as branch names:
- `error`
- `return`
- `const`
- `var`
- `fn`
- `struct`
- `enum`
- `union`
- `if`
- `else`
- `while`
- `for`
- `switch`
- `break`
- `continue`
- `try`
- `catch`
- `and`
- `or`
- Many more...

## Zig Escaping Syntax

Zig allows escaping identifiers with `@"name"`:
- Field access: `.@"error"`
- Enum variant: `.@"error"`
- Struct field: `.@"const"`

## Fix Needed

The emitter should:
1. Maintain a list of Zig reserved keywords
2. Check branch names against this list during code generation
3. Escape reserved keywords using `@"name"` syntax
4. Apply escaping consistently:
   - Union enum declarations
   - Branch constructors
   - Switch cases
   - Field access

## When This Was Hit

Test 822 (GLSL compilation) used `.error` as a branch name, which failed Zig compilation. We renamed it to `.failed` as a workaround.

## Current Status

**FAILING** - Will not compile until emitter adds keyword escaping.
