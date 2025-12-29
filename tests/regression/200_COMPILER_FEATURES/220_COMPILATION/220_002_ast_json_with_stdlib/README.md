# Test 837: --ast-json with stdlib imports

## Purpose
This test verifies that `koruc --ast-json` can successfully parse Koru files that import from the standard library (`$std`).

## Issue
Previously, the API server in koru-studio would fail when attempting to get AST from files with stdlib imports because koruc couldn't locate `koru_std` directory.

## Resolution
The module resolver in koruc looks for `koru_std` relative to the executable:
1. `executable_dir/../koru_std`
2. `executable_dir/../../koru_std` (works for `zig-out/bin/koruc`)
3. `./koru_std` (current working directory)

When spawning koruc from a different working directory, ensure the process runs from the Koru repo root or that `koru_std` is accessible via one of the search paths.

## Test Validation
```bash
# From koru repo root:
./zig-out/bin/koruc --ast-json tests/regression/830_DIRECTORY_IMPORTS/837_ast_json_with_stdlib/input.kz

# Should output valid JSON AST (not an error about FileNotFound for koru_std/ccp.kz)
```

## Expected Behavior
- Command exits with code 0
- Outputs valid JSON containing the AST
- Successfully resolves `~import "$std/ccp"`
