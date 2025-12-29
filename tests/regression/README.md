# Koru: The Event-Continuation Language

> "If it doesn't read well, it isn't good. If the language feature isn't easy to implement, it isn't right."

## Why Koru?

Koru is an **event-continuation language** designed to be embedded in Zig. It introduces a minimal syntax (`~`, `|`, `*`, `&`) for wiring events, branches, and flows—while compiling down to **optimal, pure Zig**. No runtime, no macros, no hidden costs.

### Design Tenets
- **Clarity over cleverness**: Flows are line-based, unambiguous, and easy to read. Every branch must be handled.
- **Zero-cost abstractions**: Koru compiles to the same Zig you’d write by hand, just faster and safer.
- **Strict by default**: Shapes (types) must match exactly; no implicit conversions or discards.
- **Isolation & testability**: Procs are plain Zig. Flows can be mocked and tested in isolation.
- **AI-friendly**: Declarative, minimal syntax makes it trivial for AIs to generate correct flows.

### Core Philosophy
Koru is not about adding bells and whistles. It’s about **declaring intent** as clearly as possible, then letting the compiler do the tedious parts: type checking, branch coverage, and code generation. The less ceremony in your flow code, the more focus you have for the real work—the logic inside procs.

---

# Koru Regression Tests

This directory contains the regression test suite for the Koru compiler. Tests are organized hierarchically by feature area, and the entire suite doubles as **living documentation** for the language.

## Quick Start

```bash
# Run all tests
./run_tests.sh

# Run a specific test
./run_tests.sh 000_CORE_LANGUAGE/010_BASIC_SYNTAX/010_001_hello_world
```

## Directory Structure

```
tests/regression/
├── 000_CORE_LANGUAGE/           # Top-level category
│   ├── 010_BASIC_SYNTAX/        # Sub-category
│   │   ├── 010_001_hello_world/ # Test directory
│   │   │   ├── input.kz         # The Koru source code
│   │   │   ├── expected.txt     # Expected output (if MUST_RUN)
│   │   │   ├── README.md        # Documentation (optional)
│   │   │   └── MUST_RUN         # Marker file
│   │   └── ...
│   └── ...
└── ...
```

Categories and tests are numbered for ordering: `010_`, `020_`, etc.

## Test Markers

Marker files control how the test runner handles each test:

| File | Meaning |
|------|---------|
| `MUST_COMPILE_KZ` | Test passes if Koru compilation succeeds |
| `MUST_COMPILE_ZIG` | Test passes if generated Zig compiles |
| `MUST_RUN` | Test must run and produce output matching `expected.txt` |
| `MUST_FAIL` | Test expects compilation to fail |
| `PARSER_TEST` | Compares AST output to `expected.json` |
| `SUCCESS` | Created by test runner on pass |
| `FAILURE` | Created by test runner on fail (contains reason) |
| `TODO` | Test not yet implemented |
| `SKIP` | Intentionally skipped (with reason) |
| `BROKEN` | Known to be broken (with reason) |

## Documentation Files

### README.md (Simple Documentation)

Add a `README.md` to any test directory to document what it demonstrates. This is rendered on the website as part of the lesson.

**Best practices:**
- Explain what the test demonstrates
- Break down the code with explanations
- Mention why this matters
- Link conceptually to previous/next tests

### lesson.yaml (Rich Documentation)

For complex tests (benchmarks, showcases), create a `lesson.yaml` manifest:

```yaml
# lesson.yaml
type: benchmark
title: "Descriptive Title"
description: "One-line summary"

sections:
  # Include content from a markdown file
  - type: notes
    file: NOTES.md

  # Show benchmark results as a table
  - type: results
    file: results.json

  # Tabbed view of reference implementations
  - type: references
    title: "Reference Implementations"
    files:
      - path: reference/impl.c
        label: C
        lang: c
      - path: reference/impl.rs
        label: Rust
        lang: rust
```

**Section types:**

| Type | Purpose | Required fields |
|------|---------|-----------------|
| `notes` | Markdown content | `file` |
| `results` | Benchmark table | `file` (JSON) |
| `references` | Tabbed code view | `title`, `files[]` |

**Reference file format:**
```yaml
files:
  - path: relative/path/to/file
    label: Tab Label
    lang: syntax-highlighting-language
```

## Writing Good Test Documentation

Tests read like a book when they:

1. **Build on each other** - Each test introduces one new concept
2. **Explain the "why"** - Not just what the code does, but why it matters
3. **Show the progression** - "What's Next" sections guide readers forward
4. **Stay focused** - One concept per test, explained well

## The Living Documentation Pipeline

```
tests/regression/          →  generate-lessons.js  →  lessons.json  →  /learn/*
       ↓                           ↓
  README.md                  Reads markers,
  lesson.yaml                extracts code,
  input.kz                   builds navigation
  expected.txt
```

The website at korulang.org/learn is generated directly from this test suite. Every passing test becomes a verified example. Every README becomes documentation.

## Contributing

When adding new tests:

1. Pick the right category (or create one)
2. Number it to control ordering
3. Include `input.kz` and appropriate markers
4. Add `README.md` to explain what it demonstrates
5. Run the test to verify it works
6. Run `npm run lessons` in korulang_org to regenerate docs
## Test Files

Each test directory contains:

### Required Files

**`input.kz`** - The Koru source code to compile

**`DESCRIPTION`** - Human-readable description of what the test validates

### Optional Files

**`expected.txt`** - Expected program output (for MUST_RUN tests)

**`MUST_RUN`** - Empty marker file indicating the test should execute

**`EXPECT`** - For negative tests, contains one of:
- `FRONTEND_COMPILE_ERROR`
- `BACKEND_COMPILE_ERROR`
- `BACKEND_RUNTIME_ERROR`

**`expected_error.txt`** - Substring that must appear in error message (negative tests)

**`post.sh`** - Custom validation script (advanced tests)

---

## Test Phases

Each test goes through up to 3 phases:

### Phase 1: Frontend Compilation (Zig Runtime)
**What happens:**
1. `koruc` parses `input.kz`
2. Generates `backend.zig` with embedded AST

**Success criteria:**
- No parser errors
- `backend.zig` created

**Failure modes:**
- Parse errors (syntax issues)
- Semantic errors (type mismatches, etc.)

---

### Phase 2: Backend Compilation (Zig Compile-Time)
**What happens:**
1. Zig compiles `backend.zig`
2. At compile-time, backend's `main()` executes
3. Koru compiler events run (written in Koru!)
4. Generates `output_emitted.zig`

**Success criteria:**
- Backend compiles without errors
- `output_emitted.zig` created

**Failure modes:**
- Backend compilation errors (usually in generated code)
- Code generation errors (emitter bugs)

---

### Phase 3: Execution (Runtime)
**What happens:**
1. Compile `output_emitted.zig` to executable
2. Run executable
3. Compare output to `expected.txt` OR run `post.sh`

**Success criteria:**
- Program runs without crashes
- Output matches expected (if `expected.txt` exists)
- Custom validation passes (if `post.sh` exists)

**Failure modes:**
- Runtime errors (crashes, assertions)
- Output mismatch
- Custom validation failure

---

## Negative Tests (9000_NEGATIVE_TESTS)

Tests that verify the compiler CORRECTLY REJECTS invalid code.

### Structure

```
9000_NEGATIVE_TESTS/
├── README.md               # Complete documentation
├── 9100_PARSE_ERRORS/      # Frontend syntax errors
├── 9200_SEMANTIC_ERRORS/   # Type/logic errors caught by frontend
├── 9300_BACKEND_ERRORS/    # Errors during code generation
└── 9500_RUNTIME_ERRORS/    # Expected runtime failures
```

### Example: Parse Error Test

```
9101_missing_event_keyword/
├── DESCRIPTION         # "Missing ~event keyword before declaration"
├── EXPECT             # "FRONTEND_COMPILE_ERROR"
├── expected_error.txt # "expected event declaration"
└── input.kz           # Invalid Koru code
```

**How it works:**
1. Frontend tries to compile `input.kz`
2. **Must fail** during frontend compilation
3. Error message must contain substring from `expected_error.txt`

### Expected Error Phases

**`FRONTEND_COMPILE_ERROR`**
- Parser rejects the code
- Semantic checker rejects the code
- Happens during Phase 1 (frontend)

**`BACKEND_COMPILE_ERROR`**
- Frontend succeeds, backend.zig fails to compile
- Usually indicates emitter generated invalid Zig code
- Happens during Phase 2 (backend compile-time)

**`BACKEND_RUNTIME_ERROR`**
- Everything compiles, but backend crashes during code generation
- Rare, usually indicates serious emitter bug
- Happens during Phase 2 (backend execution)

---

## Understanding Test Output

### Successful Test
```
Running 106_inline_flow_chained...
✓ Compiled input.kz → backend.zig
✓ Generated output_emitted.zig (8753 bytes)
✓ Compiled to output
✅ PASS
```

### Failed Test (Improved Error Display)
```
Running 106_inline_flow_chained...
✓ Compiled input.kz → backend.zig
✓ Generated output_emitted.zig (8753 bytes)
✗ Compilation failed
❌ Backend execution failed
  output_emitted.zig:193:28: error: use of undeclared identifier 'calculate'
              const result = calculate.handler(.{ .a = 10, .b = 20, .c = 3 });
                             ^~~~~~~~~
```

**Key improvements:**
- Shows the actual file:line:col
- Shows the error message
- Shows the offending code line
- Indented for readability

### Memory Leak Detection
```
Running 105_inline_flow_basic...
✓ Compiled input.kz → backend.zig
✓ Generated output_emitted.zig (8705 bytes)
✓ Compiled to output
✅ PASS (1 with memory leaks [not failing])
```

**With --check-leaks:**
```
❌ PASS but memory leak detected (backend)
```

---

## Common Test Patterns

### Basic Event Test
```koru
~event greet { name: []const u8 }
| done { message: []const u8 }

~proc greet = done { message: name }

~greet("World")
```

### Inline Flow Test
```koru
~event calculate { a: i32, b: i32, c: i32 }
| done { result: i32 }

~proc calculate = add(x: a, y: b)
| done sum |> multiply(x: sum.result, factor: c)
| done product |> done { result: product.result }
```

### Label Loop Test
```koru
~event outer { x: i32 }
| next { x: i32 }
| done {}

~proc outer {
    #loop outer(x: 1)
    | next n |> outer(x: n.x + 1)
    | done |> done {}
}
```

---

## Writing New Tests

### 1. Choose a Category
- **000_CORE_LANGUAGE** - Language features (events, procs, flows)
- **100_TAP_SYSTEM** - Observability taps
- **200_LABEL_LOOPS** - Control flow
- **800_BUGS** - Bug reproductions
- **9000_NEGATIVE_TESTS** - Error validation

### 2. Create Test Directory
```bash
mkdir -p tests/regression/000_CORE_LANGUAGE/999_my_feature
cd tests/regression/000_CORE_LANGUAGE/999_my_feature
```

### 3. Write Test Files

**`DESCRIPTION`:**
```
Test 999: My Feature
Tests that my amazing feature works correctly
```

**`input.kz`:**
```koru
// Your test code
~event test {}
~proc test = done {}
~test()
```

**For executable tests, add:**
```bash
touch MUST_RUN
```

**`expected.txt`:**
```
Expected output here
```

### 4. Run and Debug
```bash
./run_regression.sh 999
```

**Common issues:**
- Missing newline at end of `expected.txt`
- Trailing whitespace differences
- Incorrect phase expectations (negative tests)

---

## Advanced Features

### Custom Validation (post.sh)

For tests that need complex validation beyond text matching:

**`post.sh`:**
```bash
#!/bin/bash
# Available: $test_dir, actual.txt, output_emitted.zig, backend.zig

# Check that fusion was detected
if grep -q "__fused_" output_emitted.zig; then
    exit 0  # PASS
else
    echo "ERROR: Fusion not detected"
    exit 1  # FAIL
fi
```

### Memory Leak Detection

Enable with `--check-leaks` flag:
```bash
./run_regression.sh --check-leaks 105
```

**What it checks:**
- Frontend leaks (during `input.kz` → `backend.zig`)
- Backend leaks (during `backend.zig` → `output_emitted.zig`)
- Output leaks (during final executable compilation)

**Note:** Leaks don't fail tests by default (just warnings). Use `--check-leaks` to make them failures.

---

## Test Numbering Convention

### Core Language (000-099)
- **001-050**: Basic features (events, procs, branches)
- **051-100**: Advanced features (subflows, inline flows)
- **101-150**: Complex compositions

### Tap System (100-199)
- **101-125**: Basic taps
- **126-150**: Advanced tap features

### Labels (200-299)
- **201-225**: Basic loops
- **226-250**: Nested loops
- **251-275**: Complex control flow

### Bugs (800-899)
- **800-850**: Critical bugs
- **851-899**: Edge cases

### Negative Tests (9000-9999)
- **9100-9199**: Parse errors
- **9200-9299**: Semantic errors
- **9300-9499**: Backend errors
- **9500-9599**: Runtime errors

---

## Debugging Failed Tests

### 1. Check Which Phase Failed
```
❌ Frontend compilation failed  → Check input.kz syntax
❌ Backend compilation failed   → Check backend.zig (generated code)
❌ Backend execution failed     → Check output_emitted.zig (final code)
❌ Output mismatch              → Check expected.txt vs actual.txt
```

### 2. Inspect Generated Files
```bash
cd tests/regression/000_CORE_LANGUAGE/106_inline_flow_chained

# View frontend output
cat backend.zig | less

# View final generated code
cat output_emitted.zig | less

# View error logs
cat compile_backend.err
cat backend.err
```

### 3. Run Phases Manually
```bash
# Frontend only
./zig-out/bin/koruc input.kz

# Backend compilation
cd tests/regression/.../106_inline_flow_chained
zig build

# Backend execution
./backend

# Final compilation
zig build-exe output_emitted.zig
```

### 4. Compare with Working Tests
```bash
# Find similar passing tests
./run_regression.sh 105  # Simpler inline flow
diff tests/regression/.../105_*/output_emitted.zig \
     tests/regression/.../106_*/output_emitted.zig
```

---

## CI/CD Integration

### Exit Codes
- **0**: All tests passed
- **1**: Some tests failed
- **2**: Unit tests failed (but regression tests might pass)

### Running in CI
```bash
# Full suite with leak checking
./run_regression.sh --check-leaks

# Specific patterns for fast feedback
./run_regression.sh 0*  # Core language only
./run_regression.sh 91* # Parse errors only
```

### Baseline Tracking
The suite tracks baseline test counts:
```
📊 Same as baseline (RESULTS: 88/120)  # No change
📈 +3 tests compared to baseline       # Improvement!
📉 -2 tests compared to baseline       # Regression
```

---

## Best Practices

### DO:
- ✅ Write focused, single-purpose tests
- ✅ Use descriptive test names
- ✅ Include comprehensive DESCRIPTION files
- ✅ Test edge cases with negative tests
- ✅ Keep expected output minimal

### DON'T:
- ❌ Test multiple features in one test
- ❌ Use random or time-dependent output
- ❌ Hardcode absolute paths
- ❌ Forget to mark tests with MUST_RUN if they should execute
- ❌ Skip writing DESCRIPTION (future you will thank you!)

---

## Future Improvements

Planned enhancements:
- Parallel test execution
- Test dependency tracking
- Performance benchmarking integration
- Coverage analysis
- Automatic test generation from bug reports

---

*The regression suite is the safety net that lets us refactor fearlessly.* 🛡️
