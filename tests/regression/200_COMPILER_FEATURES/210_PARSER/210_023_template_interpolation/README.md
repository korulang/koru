# Test 104: Source Parameter Basic Access

## What This Test Proves

This test validates the foundational infrastructure for Source parameters - the pillar of Koru's metaprogramming system.

### Verified Functionality

1. **Source Parameter Syntax Works**
   - Events can declare `Source[PhantomType]` parameters
   - The `[PhantomType]{ }` invocation syntax is recognized by the parser
   - Phantom type annotations (like `HTML`) are captured

2. **Source Text Capture**
   - Raw text content inside `[Type]{ }` blocks is preserved exactly
   - Proc bodies can access the source text via the `source` parameter
   - Text is passed through as `[]const u8`

3. **Source Serialization**
   - Source parameters serialize correctly to JSON AST
   - The serialized form includes:
     - `text`: The raw source content
     - `location`: Where the Source block appears in the file
     - `scope`: Structure for captured bindings (empty at module-level)
     - `phantom_type`: The type annotation from `[Type]`

4. **Comptime Execution**
   - Events with Source parameters are correctly identified as comptime-only
   - The flow invoking `renderHTML` executes during backend compilation
   - The proc receives the source text and can process it

## AST Structure

The key AST node showing Source serialization:

```json
{
  "name": "source",
  "value": "    <div>\n        <h1>Hello, World!</h1>...",
  "source_value": {
    "text": "    <div>\n        <h1>Hello, World!</h1>...",
    "location": {
      "file": "tests/regression/050_PARSER/104_template_interpolation/input.kz",
      "line": 31,
      "col": 0
    },
    "scope": {
      "bindings": []
    },
    "phantom_type": "HTML"
  }
}
```

## What's Next

This test establishes the foundation. Future tests will build on this to verify:

- **Scope Capture**: Continuation bindings appear in `scope.bindings`
- **Template Interpolation**: Parsing `${}` syntax and substituting values
- **Code Generation**: Procs that emit runtime code based on Source inspection

## Significance

This is THE PILLAR of Koru metaprogramming. With Source parameters working end-to-end, we can now build:

- Template engines with compile-time parsing and runtime interpolation
- Embedded DSLs that transform to efficient runtime code
- Code generators that inspect lexical scope at the call site
- Any form of syntax-aware metaprogramming

The infrastructure is solid. Now we build upward.
