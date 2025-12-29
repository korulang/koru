# Koru Integration Test Plan

## 🔥 TEST PHILOSOPHY: INSANE AND HONEST!
**"Nothing is more honest than failing tests. Nothing is more insane than passing tests!"**

Failing tests are GOLD - they show us exactly what's broken. Every failing test is a bug we can fix!

## Goal
Create a comprehensive test suite that:
1. Documents each language feature
2. Verifies correct behavior
3. Catches regressions
4. Serves as examples for users

## Test Coverage Status: 13/15 passing (87%)

### ✅ PASSING Tests (The Insane Ones)
- [x] 01_basic_event.kz - Basic event + proc with correct union syntax
- [x] 02_void_event.kz - Branch-less events (void output) 
- [x] 03_pipeline.kz - Pipeline operator with binding propagation
- [x] 04_nested_continuations.kz - Indented continuations in pipelines
- [x] 05_nested_continuations_full.kz - Complex nested continuations
- [x] 07_namespaces.kz - Namespace merging and deduplication
- [x] 09_escaped_fields.kz - Field name escaping (with workaround)

### ❌ FAILING Tests (The Honest Ones - These are VALUABLE!)
- [ ] 06_void_events_full.kz - FAILS: `const out1 =` for void return
- [ ] 08_labels_loops.kz - FAILS: Label recursion uses wrong variable

### 🐛 Known Bugs Found by Tests
1. **Parser crashes on `f.@"error"`** - Can't handle escaped field access
2. **Label generation bug** - Uses `input` instead of `out1` for recursion
3. **Void assignment** - Generates `const out1 =` for void functions
4. **Multiple flows limitation** - Can't have multiple test flows in one file
5. **Unused empty payload capture** - Generates `|_started|` for empty structs

### 📝 Tests We Should Write (More Bugs to Find!)
- [ ] 10_terminal_marker.kz - Terminal flow marker (_) edge cases
- [ ] 11_empty_payloads.kz - Events with empty struct {} payloads
- [ ] 12_multi_branch.kz - Events with 3+ branches
- [ ] 13_field_access.kz - Nested field access (e.g., s.user.name)
- [ ] 14_pre_invocation_labels.kz - Label before event invocation

### 🐛 Edge Cases to Test
- [ ] keyword_escaping.kz - Using Zig keywords as identifiers
- [ ] deep_nesting.kz - Very deep continuation nesting
- [ ] large_payloads.kz - Events with many fields
- [ ] unicode_strings.kz - Non-ASCII in string literals

### 🔧 Regression Tests
- [ ] correct_union_syntax.kz - Ensures `.{ .@"branch" = .{} }` works
- [ ] void_no_switch.kz - Void events don't generate switch statements
- [ ] single_main_flow.kz - Only one top-level flow allowed

## Test Structure

Each test file should:
```koru
// Test: <Feature being tested>
// Expected: <What should happen>
// Verifies: <Specific behavior or bug fix>

<minimal code to test the feature>
```

## Running Tests

```bash
# Run all tests
./test_integration.sh

# Run single test
./zig-out/bin/koruc tests/integration/01_basic_event.kz
zig build-exe 01_basic_event.zig
./01_basic_event
```

## Success Criteria

A test passes if it:
1. Compiles from .kz to .zig without errors
2. Compiles from .zig to executable without errors  
3. Runs without crashing (exit code 0)
4. Produces expected output (if applicable)