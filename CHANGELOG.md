# Changelog

## [0.1.3] - 2026-02-17

~100 commits since 0.1.2 (Jan 28). Major areas: language syntax, compiler hardening, interpreter speedups, build system, and the dead strip pass.

### Breaking Changes

- **Inline flows removed.** Events must use continuations, not call/return. All `inline_flows` fields purged from the AST. (`c47d68a`, `f732be3`, `fdd0be`, `2098d42`)
- **`~impl` syntax rejected.** `~proc =` form is no longer accepted; use named implementations instead. (`a64cf08`)
- **`~pub proc` rejection.** Public visibility on procs is now a compile error. (`a64cf08`)
- **Tap syntax changed.** Old `~source -> dest` form replaced with `~tap(source -> dest)`. (`8c816c5`, `7d57f47`)

### Language & Syntax

- **`struct` keyword.** First-class struct declarations with field shadowing support. (`32681fe`)
- **Array indexing in captures.** `captured { }` blocks now support array subscript access. (`2569a85`)
- **Nested when-guards.** When clauses can now appear in nested continuation contexts. (`1181bef`, `5df2a82`)
- **Comments in continuations.** Parser now correctly handles comments inside continuation chains. (`c8b5b30`)
- **Label loop scopes.** Loops can be labeled for break/continue targeting. (`32681fe`)
- **`captured` branch rename.** The `done` branch in captures is now `captured` for clarity. (`59c3261`)
- **`is_optional` flag.** Branches can be marked optional for synthesized continuation support. (`353f710`, `7fce2a9`)

### Compiler

- **Comptime pipeline.** Comptime flows can now return `Program` to rewrite the AST, with pointer/const-aware type detection. (`3a386bf`, `df2ab9b`)
- **Dead strip pass.** New compiler pass strips unreachable flows, with `@retain` annotation to preserve specific items. (`c0956a8`, `cb8ab8c`)
- **Source markers.** Emitted code now includes `FLOW`, `PROC`, `BRANCH`, `INLINE`, and `SUBFLOW` location markers for traceability. (`ec467f7`, `7f7ec52`)
- **FlowChecker.** Frontend/backend mode split for flow validation; runs KORU100 unused binding check in frontend mode. (`ff6da80`, `b3f241d`, `07571ab`)
- **AST rewrite.** `SubflowImpl` → `Flow` unification; `impl_of`/`is_impl` fields preserved across transforms. (`a310223`, `908bdb3`)
- **Transform hardening.** Nested transform replacements fixed; catchall parser hardened; same-pointer transform returns handled without aborting. (`c516fa4`, `94bffc3`, `777d354`, `c2be540`)
- **Module-qualified events.** Cross-module tap transforms and compiler:requires matching now respect module qualifiers. (`06a21ba`, `2d521cb`, `cc73bdb`)
- **CCP fixes.** Constant propagation pass corrected for inline flow removal. (`a64cf08`)
- **Metatype bindings.** Catch-all optional branches now emit metatype struct synthesis. (`a960449`, `4026233`)

### Build System

- **Cross-compilation via `build:config`.** Variant-aware emission supports target triples through Koru's own build system. (`d32e8f8`)
- **`ReleaseSmall` default.** Production builds now default to `ReleaseSmall` instead of `Debug`. (`22813b4`)
- **`--debug` flag.** Opt into debug builds during development. (`22813b4`)
- **`--tiny` flag.** Minimal binary size optimization. (`f5e2903`)
- **Release script.** New `scripts/release.sh` automates cross-compilation, dist sync, and packaging for npm.
- **Zig package dependencies.** Support for external Zig packages (e.g., vaxis). (`c593f30`)

### Interpreter

- **Flow parser (144x speedup).** Lightweight flow parser replaces full AST parser for interpreter eval. (`ba4a4ba`, `071371a`)
- **Thread-local state pooling.** Cached interpreter eval with thread-local resource reuse. (`7eff5b9`)
- **`~if` runtime conditionals.** Interpreter supports runtime conditional branching. (`929d498`)
- **Honest bindings.** Branch metatype exposed; identity branches covered in tests. (`b32cb6d`, `2d69c41`, `656058e`)

### Error Messages

- **5 parser quick wins.** Better messages for special characters in source blocks, nested flows inside continuations, and more. (`c8b5b30`, `741dba3`, `1ef32bd`)
- **Negative test suite.** `MUST_FAIL` markers for tests that verify error cases. (`e89a8de`)
- **Real source locations.** Error reporter now uses actual file/line from source markers. (`ec467f7`)
- **Ambiguous module error.** Clear diagnostic when both `foo.kz` and `foo/` exist. (`20766e2`)

### Standard Library

- **`@koru/sqlite`** — First official library package. (`2b2f75f`)
- **`rings` module** — New stdlib module. (`adc95f4`)
- **`runtime_control`** — Expression evaluator for runtime conditionals. (`929d498`)
- **`parser` module** — Parser generator with derive handler, AST JSON dump, and ParseResult re-export. (`7f0d56d`, `81f02cd`, `dd23226`, `b1cd86d`)
- **`package` module** — CLI `koruc init` command and `$node` path alias. (`0947731`, `14ac5ba`)
- **Phantom types.** State unions, auto-dispose inserter with `@scope` annotations, void chain validation. (`074e917`–`e24eb50`, `160b069`)

### Bug Fixes

- **Parser:** Preserve source args during module imports (`cc73bdb`), fix brace depth line advancement (`c5c9759`), handle `plain_value` in branch constructors (`b3a564a`).
- **Emitter:** Fix `is_void_step` for assignment steps (`84bc8e7`), wrap when-guard conditions in parens for valid Zig (`5df2a82`), fix variable shadowing in if-statement codegen (`0213bec`).
- **Taps:** Support taps on labeled invocations (`483f74b`), module-qualified event patterns (`e72acff`), prevent infinite recursion in wildcard taps (`6476d41`), multi-branch fan-out (`da8fd88`).
- **Build:** Fix `joinPath` stack memory corruption via heap allocation (`504e8ec`), prevent backend overwriting `.kz` source files (`121b48e`).
- **Interpreter:** `Value.toJson` serialization and arena lifetime for error messages (`8067750`).
- **Misc:** Unique type names for nested captures (`7c53012`), fmt escape handling (`8d8f2ae`), virtual flow lookup dropped (`7b1d296`).

### Testing

- **487/565 tests passing** (86.2%), up from 469 at 0.1.2.
- Regression snapshot infrastructure with timestamped JSON and `run_regression.sh` tooling.
- New test coverage: phantom imports, tap when-clause filtering, interpreter identity branches, optional branches, vaxis standalone example.

### Packaging

- Duplicate `koru-*` binaries removed from dist (saves ~33MB). The npm wrapper (`bin/koruc`) only uses `koruc-*` names.
- Old `.tgz` tarballs cleaned from dist.
- `src/main.zig` version string now kept in sync (was stuck at `0.1.0` for 0.1.1 and 0.1.2).
