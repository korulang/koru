# 050_PARSER: Parser Test Category

This category provides **gold-standard testing** for Koru's parser, validating both successful parses (AST structure) and syntax error cases (precise error messages).

## Philosophy

**The parser's ONLY job is syntax checking** - it converts source code to AST. It does NOT validate semantics (duplicate names, undefined references, type errors, etc.). Those are handled by **compiler passes** tested separately.

Parser tests are **isolated from everything after parsing**. They verify:
1. **What the parser produces** (AST structure)
2. **How it rejects invalid syntax** (error messages with locations)
3. **Syntax equivalence** (different valid syntax → same AST)

This makes:
- Parser changes **safe** (exact AST validation)
- Error messages **high quality** (tested precisely)
- Testing **fast** (no code generation, no semantic analysis)

## Test Types

### Positive Tests: AST Validation

**Marker:** `PARSER_TEST`

**Structure:**
```
050_PARSER/XXX_test_name/
  input.kz           # Koru source code
  expected.json      # Expected AST structure
  PARSER_TEST        # Marker file
```

**How it works:**
1. Compiler runs with `--ast-json` flag
2. Generated JSON is compared against `expected.json`
3. Test passes if structures match exactly

**Example:**
```koru
// input.kz
~event greet { name: []const u8 }
| greeting { msg: []const u8 }
```

```json
// expected.json (simplified)
{
  "items": [{
    "event_decl": {
      "path": {"segments": ["greet"]},
      "input": {
        "fields": [{"name": "name", "type": "[]const u8"}]
      },
      "branches": [
        {"name": "greeting", "payload": {"fields": [{"name": "msg", "type": "[]const u8"}]}}
      ]
    }
  }]
}
```

### Negative Tests: Syntax Error Validation

**Marker:** `EXPECT` with `FRONTEND_COMPILE_ERROR`

**Structure:**
```
050_PARSER/09X_error_name/
  input.kz           # Invalid Koru syntax
  expected_error.txt # Exact expected error message
  EXPECT             # Contains: FRONTEND_COMPILE_ERROR
```

**What belongs here:** ONLY syntax errors (unclosed braces, invalid tokens, missing required syntax elements). NOT semantic errors (duplicate names, undefined references, type mismatches) - those are tested via compiler passes.

**Error Message Format (REQUIRED):**
```
input.kz:5:12: error: expected '}', found 'end of file'
  | success { result: u32
            ^
```

**Components:**
- **Location:** `file:line:col`
- **Severity:** `error` (or `warning`/`note`)
- **Message:** Specific, actionable description
- **Context:** Source line with caret pointing to problem

**Bad Example (too vague):**
```
error:
```

**Good Example (precise and actionable):**
```
input.kz:3:1: error: expected '}', found '|'
    2 | ~event write {
    3 |     value: i32
      |                ^
    4 | | success {}
```

## Directory Structure

Tests use **flexible numbering** within the 050_PARSER category:
- Start with simple numbers (050, 051, 052...)
- Add granularity when needed (0520, 0521... to subdivide 052)
- Running `./run_regression.sh 052` runs ALL 052x tests

**Convention:**
- **050-069**: Positive tests (valid syntax → AST validation)
- **070-089**: Reserved for future expansion
- **090-099**: Parse error tests (invalid syntax → error messages)

### Current Tests

**Positive Tests (050-069):**
- 050: Multiline event declaration
- 051: Multiline branch constructor

**Parse Error Tests (090-099):**
- 090: Unclosed input brace
- 091: Unclosed branch brace
- 092: Unclosed string
- 093: Invalid pipe operator
- 094: Missing event name
- 095: Missing field colon
- 096: Unclosed flow parentheses
- 097: Invalid continuation
- 098: Unexpected token
- 099: Unclosed annotation

**Note:** Semantic errors (duplicate names, undefined references, type errors) are NOT tested here - they're tested via individual compiler passes.

## Creating New Tests

### Positive Test
1. Write `input.kz` with the Koru code
2. Run: `koru --ast-json input.kz > expected.json`
3. Review and clean up the JSON (remove noise, focus on structure)
4. Create `PARSER_TEST` marker file
5. Run test to verify

### Syntax Error Test
1. Write `input.kz` with invalid **syntax** (not semantic errors!)
2. Run compiler and capture parse error message
3. Copy EXACT error message to `expected_error.txt`
4. Create `EXPECT` file with `FRONTEND_COMPILE_ERROR`
5. Run test to verify

**Remember:** If the error could only be detected by analyzing the AST (not during parsing), it's NOT a parse error!

## Quality Standards

### Error Messages Must:
- ✅ Include precise location (file:line:col)
- ✅ Show source context with caret
- ✅ Be actionable (suggest fixes when possible)
- ✅ Be consistent in format
- ❌ Never be generic ("error:" alone)
- ❌ Never omit location information

### AST Tests Must:
- ✅ Cover all syntax variations
- ✅ Test edge cases (empty, nested, etc.)
- ✅ Verify semantic equivalence (multiline = single-line)
- ✅ Be maintainable (clean, focused JSON)

## Benefits

1. **Regression protection** - Parser changes can't break unexpectedly
2. **Error quality** - Forces good error messages
3. **Documentation** - Tests show how syntax works
4. **Confidence** - Know exactly what parser produces
5. **Speed** - Tests run fast (no code generation)

## Source-Based Metaprogramming

**Design Decision (2025-10-22)**: Koru uses **Source + CapturedScope** as universal metaprogramming substrate.

### The Design

Source parameters capture THREE things:
1. **Text** - Raw source (can be ANY language: Koru, HTML, SQL, Lua)
2. **Location** - Where it started (for error messages pointing to original)
3. **Scope** - Available bindings (lexical capture!)

```koru
const user_name = "Alice";
~std.testing:test(name: "example") {
    ~mock.service = success { value: 42 }
    ~assert.equals(value, user_name)
}
```

### Why Source > FlowAST

**FlowAST approach** (explored in tests 054-058):
- Required double-pass parsing to resolve forward references
- Only worked for Koru code
- Complex parser with type lookup during parsing

**Source approach** (test 059):
- ✅ No forward reference problem (Source is opaque text)
- ✅ No double-pass parsing needed (single-pass parser)
- ✅ Works for ANY language (HTML, SQL, Lua, GLSL, etc.)
- ✅ Natural scope capture (variables available at invocation)
- ✅ Flexible (comptime proc decides when/how to parse)

See `058_forward_reference_flowast/DESIGN_DECISION.md` for complete analysis.

### Test Coverage

| Test | Feature | Status |
|------|---------|--------|
| **055** | Source parameter (basic) | ✅ PASSING |
| **059** | Source with scope capture | 🚧 Phase 1 complete, Phases 2-4 pending |

### Superseded Tests (FlowAST Approach)

The following tests explored FlowAST-based metaprogramming. We pivoted to Source because it's simpler, more powerful, and more flexible.

| Test | Original Feature | Superseded By |
|------|------------------|---------------|
| 054 | FlowAST parameters | Source (059) |
| 056 | Implicit FlowAST blocks | Source (059) |
| 057 | FlowAST with params | Source (059) |
| 058 | Forward references | Source design decision |

### FlowAST Still Exists

FlowAST remains as a TYPE for ambient injection:

```koru
~event thread:spawn { this: *FlowAST }
```

The compiler injects `__koru_this_flow` automatically for threading/AST manipulation.

**Use FlowAST for**: Ambient context (compiler injection)
**Use Source for**: Captured blocks (with scope!)

## Future Directions

- **Complete Source + CapturedScope implementation** (test 059, Phases 2-4)
- **Add CompilerContext** for comptime procs (parser/emitter access)
- Add error recovery tests (how parser continues after errors)
- Add fuzzing tests (random input validation)
- Add performance tests (parse speed benchmarks)
- Add incremental parse tests (for IDE support)

---

**This category makes Koru's parser world-class!** 🚀
