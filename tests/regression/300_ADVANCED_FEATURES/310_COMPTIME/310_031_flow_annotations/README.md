# Test 641: Flow Annotations - Parametrized Annotations on Flow Invocations

## Purpose

Tests that Flow invocations can have parametrized annotations and that the annotation parser correctly extracts arguments from annotations like `~[depends_on("a", "b", "c")]`.

## What It Tests

1. **Simple annotations**: `~[pure]` - annotations without parameters
2. **Single argument**: `~[depends_on("simple")]` - parametrized annotation with one arg
3. **Variadic arguments**: `~[depends_on("a", "b", "c")]` - multiple arguments
4. **Combined annotations**: `~[pure|depends_on("x")]` - multiple annotations on one flow

## Architecture

This test validates the annotation parser library (`src/annotation_parser.zig`) working with Flow annotations:

- Parser (`parser.zig`) extracts annotations from `~[...]` syntax
- Annotations stored in `Flow.annotations` field
- Annotation parser library interprets parametrized annotations
- Build system uses `annotation_parser.getCall()` to extract dependencies

## Expected Behavior

The compiler should:
1. Parse all Flow invocations with their annotations
2. Store annotations in the AST
3. Successfully compile (no errors)
4. Annotations are available for build step dependency resolution

## Related

- `src/annotation_parser.zig` - Annotation parsing library
- `src/ast.zig` - Flow.annotations field
- `src/parser.zig` - Annotation parsing during Flow creation
- Test 642: command.zig collection
- Test 643-645: Build step dependency resolution
