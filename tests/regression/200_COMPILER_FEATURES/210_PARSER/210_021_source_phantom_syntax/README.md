# Test 102: Source Phantom Type Syntax

## Purpose

Verify that the parser recognizes the new `[PhantomType]{ }` syntax for Source blocks, which:
1. Disambiguates Source blocks from branch constructors
2. Makes phantom types visible at invocation sites
3. Enables type checking and validation

## Syntax Design

### Single Source (implicit parameter)
```koru
~event render { template: Source[HTML] }

~render [HTML]{
    <div>content</div>
}
```

### Multiple Sources (explicit named fields)
```koru
~event page { template: Source[HTML], query: Source[SQL] }

~page []{
    template: [HTML]{ <div>...</div> },
    query: [SQL]{ SELECT * FROM users }
}
```

### Mixed Parameters + Source
```koru
~event render { color: []const u8, template: Source[HTML] }

~render(color: "red") [HTML]{
    <div>content</div>
}
```

### Empty Phantom Type
```koru
~event capture { source: Source[] }

~capture []{
    arbitrary content
}
```

## What This Tests

1. **Parser recognizes `[...]` before `{`** as Source block marker
2. **Phantom type annotation captured** in AST (e.g., `HTML`, `SQL`, empty)
3. **Disambiguates from branch constructors** - no parser confusion
4. **Handles nested braces** within Source content correctly
5. **Works with multiple Source parameters** using `[]{ field: [Type]{ } }` syntax

## Design Decisions

### Why `[Type]{ }` instead of `{ }`?
Old syntax was ambiguous:
```koru
~getUserData
| data u |> renderHTML {
    <div>${u.name}</div>
}
```

Parser saw `renderHTML {` and couldn't determine:
- Is this a Source block for `renderHTML` event?
- Or a branch handler for a `renderHTML` branch?

The `[Type]` prefix unambiguously marks Source blocks.

### Why require phantom types?
- **Self-documenting**: Call sites show expected content format
- **Type safe**: Validator can check HTML → HTML, SQL → SQL
- **Future-proof**: Enables content validation/linting

### Why `[]` for multiple Sources?
The empty brackets `[]` signal "collection of Sources", each with their own phantom type annotation. This:
- Avoids special syntax like `[*]`
- Uses familiar "collection" semantics
- Scales to future metatypes (Expression, etc.)

## Parser Implementation

The parser needs to:
1. **Look ahead for `[` before `{`** when expecting Source argument
2. **Parse phantom type** between `[` and `]`
3. **Store annotation** in `Source` AST node
4. **Handle both syntaxes**:
   - `[Type]{ content }` - single Source
   - `[]{ field: [Type]{ }, ... }` - multiple Sources

Key insight: **Parser stays dumb** - it just captures the annotation string. Validation happens later.

## AST Changes

`Source` struct needs:
```zig
pub const Source = struct {
    text: []const u8,
    location: errors.SourceLocation,
    scope: CapturedScope,
    phantom_type: ?[]const u8,  // NEW: Phantom type annotation from call site
};
```

## Current Status

**NOT YET IMPLEMENTED** - This test will fail until parser is updated.

## Next Steps

1. ✅ Create test input (this file)
2. ⏳ Update AST to store phantom_type
3. ⏳ Update parser to recognize `[...]{ }` syntax
4. ⏳ Verify test passes
5. ⏳ Update all existing Source tests to new syntax

## Verification

Once implemented, verify with:
```bash
./run_regression.sh 102
```

Expected: All four test cases compile and run successfully.

---

**Test Type:** Parser validation + End-to-end
**Status:** 🚧 Not yet implemented
