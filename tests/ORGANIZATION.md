# Test Organization

## Directory Structure

### /integration
**Purpose**: Systematic tests of language features  
**Naming**: Numbered for execution order (01_, 02_, etc.)  
**Requirement**: Must compile AND run successfully

Current tests:
- 01_basic_event.kz - Basic event and proc
- 02_void_event.kz - Branch-less events
- 03_pipeline.kz - Pipeline operator
- 04_nested_continuations.kz - Indented continuations
- 05_nested_continuations_full.kz - Complete nested test
- 06_void_events_full.kz - Comprehensive void event test
- 07_namespaces.kz - Namespace handling
- 08_labels_loops.kz - Labels and loops

### /features
**Purpose**: Test specific language features in detail  
**Naming**: Feature-descriptive names  
**Requirement**: Should test edge cases and variations

Current tests:
- branch_constructor_test.kz - Branch constructor validation
- subflow_test.kz - Basic subflow functionality
- subflow_output_test.kz - Subflow output shapes
- subflow_shape_test.kz - Shape checking in subflows
- subflow_with_constructors.kz - Combined features

### /broken
**Purpose**: Known failing tests for tracking bugs  
**Naming**: Descriptive of the bug  
**Requirement**: Document why it fails

Current tests:
- broken.kz - Parser test case
- invalid_branch_constructor.kz - Invalid expressions in constructors
- pre_label_test.kz - Incomplete branch coverage
- recursion_test.kz - Multiple top-level flows
- label_variations.kz - Multiple top-level flows

### /scratchpad
**Purpose**: Temporary test files  
**Naming**: Any  
**Requirement**: Can be deleted anytime

### /regression
**Purpose**: Tests for specific bug fixes  
**Naming**: bug_XXX.kz or issue_XXX.kz  
**Requirement**: Must pass to prevent regression

## Test Guidelines

### Integration Tests
- Test ONE feature per file
- Use minimal code
- Include clear comments
- Number for dependency order

### Feature Tests  
- Test edge cases
- Test error conditions
- Test combinations
- Can be larger/complex

### Broken Tests
- Include error message
- Reference issue/bug number
- Keep until fixed

## Running Tests

```bash
# Run all tests
./test_integration.sh

# Run specific directory
for f in tests/integration/*.kz; do
    ./zig-out/bin/koruc "$f"
done
```