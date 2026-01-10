# Task 001: Build Module Deduplication

## Status
- [x] Pending

## Problem

When a Koru program imports multiple standard library modules that share dependencies, Zig 0.15 fails with:

```
error: file exists in modules 'ast' and 'ast0'
note: files must belong to only one module
```

This happens because each `~std.build:requires` block independently adds its module imports, and when merged, the same file (e.g., `/usr/local/lib/koru/src/ast.zig`) gets added under multiple module names.

**Failing tests**: 430_017, 430_018, 430_022

## Context

### How Koru Build Works

1. Koru source files can include `~std.build:requires { ... }` blocks containing Zig build code
2. These blocks declare module dependencies needed at runtime
3. The compiler collects ALL `~std.build:requires` blocks from the program and imported std libraries
4. `backend.zig` generates `build_output.zig` which contains the merged build requirements
5. Zig's build system compiles the final executable with these modules

### The Conflict

When you import both `$std/interpreter` and `$std/eval`:
- `interpreter.kz` has `~std.build:requires` that adds `ast_module` as "ast"
- `eval.kz` has `~std.build:requires` that adds `ast_module` as "ast"
- The test itself might ALSO add `ast_module` as "ast"
- Result: same file added multiple times under slightly different names

### Example from 430_017

```koru
~import "$std/runtime"
~import "$std/build"
~import "$std/eval"

~std.build:requires {
    // ... adds ast_module ...
    exe.root_module.addImport("ast", ast_module);
}
```

The interpreter.kz also adds ast. When merged, we get both "ast" and "ast0" pointing to the same file.

## Success Criteria

1. Tests 430_017, 430_018, 430_022 should pass (no module conflict)
2. Importing multiple std libs with shared deps should work
3. Existing tests should not regress

## Files to Examine

### Primary
- `src/backend.zig` - Generates build files, look for build requirement handling
- `src/emitter.zig` - May handle build requirement collection

### Standard Library (to understand the requires blocks)
- `koru_std/interpreter.kz` - Has build:requires adding parser modules
- `koru_std/eval.kz` - Has build:requires adding ast modules
- `koru_std/build.kz` - Defines the build:requires transform

### Test Cases
- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_017_expr_evaluator/input.kz`
- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_018_runtime_if/input.kz`
- `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_022_if_expression_parsing/input.kz`

## Proposed Solution Direction

When generating `build_output.zig`, deduplicate module imports:
1. Track which source files have already been added as modules
2. If a file is already imported under name X, don't create a new import Y for the same file
3. Reuse the existing module reference

The deduplication should happen at build file generation time, not at parse time.

## Constraints

- Don't change the `~std.build:requires` syntax or semantics
- Don't break tests that currently pass
- Solution should be in the build generation, not require users to change their code
