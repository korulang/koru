# Koru Test Suite

This directory contains systematic integration tests for the Koru language compiler.

## Structure

```
tests/
├── integration/     # Feature-specific integration tests
│   ├── 01_basic_event.kz
│   ├── 02_proc_implementation.kz
│   ├── 03_simple_flow.kz
│   ├── 04_pipeline.kz
│   ├── 05_nested_continuations.kz
│   ├── 06_void_events.kz
│   ├── 07_labels.kz
│   ├── 08_subflows.kz
│   └── ...
├── broken/         # Known failing tests (for tracking bugs)
│   ├── keyword_conflicts.kz
│   ├── unused_captures.kz
│   └── ...
└── regression/     # Tests for specific bug fixes
    ├── union_constructor_syntax.kz
    ├── memory_leak.kz
    └── ...
```

## Running Tests

```bash
# Run all integration tests
./test_integration.sh

# Run specific test
./zig-out/bin/koruc tests/integration/01_basic_event.kz
```

## Test Naming Convention

- `01_feature.kz` - Basic feature tests (numbered for order)
- `feature_edge_case.kz` - Edge cases and variations
- `bug_XXX.kz` - Regression tests for specific bugs

## Test Guidelines

1. Each test should focus on ONE language feature
2. Tests should be minimal - just enough to verify the feature
3. Use comments to explain what's being tested
4. Include both positive and negative cases where relevant
5. Tests should compile AND run successfully (unless in `broken/`)

## Current Status

See `INTEGRATION_TEST_RESULTS.md` for the latest test run results.