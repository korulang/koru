# Codex Review Findings (Static)

Scope: static review of parser, shape checker, emitter, and compiler bootstrap plus regression suite notes.

## CRITICAL

### 1) Parse errors can be silently ignored in default CLI flow
- **What**: Parser defaults to lenient mode and `main` only prints errors when `parse()` throws. The emitter skips `parse_error` nodes.
- **Refs**: `src/parser.zig:324`, `src/main.zig:5535`, `src/visitor_emitter.zig:905`
- **Bad input**:
  ```
  ~event foo {
  | ok {}
  ```
- **Current error**: None (parse_error node emitted, compile continues until later failure or emits Zig errors).
- **Should say**: `parse error: expected '}' to close event input shape` (with line/column), and fail compilation.

### 2) Nested continuations with `when` guards are parsed as `parse_error`
- **What**: Known failing test; valid flows with nested `when` guards become `parse_error` nodes.
- **Refs**: `src/parser.zig:7435`
- **Bad input**:
  ```
  ~run()
  | ready t |> poll()
      | key k when (k.code == 'q') |> cleanup()
          | done |> _
      | key k |> handle_key(k)
          | done |> _
  | err _ |> _
  ```
- **Current error**: `parse_error` node in AST; later compilation fails or silently skips.
- **Should say**: No error; parse into flow with nested continuations and guards.

### 3) Subflow impl at EOF returns `UnexpectedEof` without a reporter error
- **What**: `parseSubflowImpl` returns error without emitting a parse error, so the compiler only shows a generic failure.
- **Refs**: `src/parser.zig:3910`
- **Bad input**:
  ```
  ~event foo {}
  ~foo =
  ```
- **Current error**: `Failed to parse source` (no location).
- **Should say**: `parse error: expected subflow body after '='` (with line/column).

### 4) Label jump errors lack diagnostics and location
- **What**: Unknown label or bad label usage returns early without adding reporter errors.
- **Refs**: `src/shape_checker.zig:1213`, `src/shape_checker.zig:1277`
- **Bad input**:
  ```
  ~run()
  | done |> @missing()
  ```
- **Current error**: Generic `Unknown label referenced` (no line/column or label name).
- **Should say**: `unknown label '@missing'` at the exact location.

### 5) Regression suite documents two real bugs (should not be ignored)
- **Loop over imported module event fails resolution**
  - **Refs**: `tests/regression/000_CORE_LANGUAGE/040_CONTROL_FLOW/235_loop_imported_module/input.kz:1`
  - **Bad input**:
    ```
    ~import "$app/mylib"
    ~#loop app.mylib:tick()
    | next _ |> @loop()
    | done |> _
    ```
  - **Current error**: `Event not found` / `Cannot find event declaration for loop variable`.
  - **Should say**: Resolve imported event or emit precise error with missing symbol and path.
- **Phantom obligations not enforced across label jumps**
  - **Refs**: `tests/regression/300_ADVANCED_FEATURES/370_PHANTOM_TYPES/370_020_label_jump_obligation/input.kz:1`
  - **Bad input**: (see test file)
  - **Current error**: Compiles successfully (bug).
  - **Should say**: `phantom obligation not discharged before @loop` (with binding details).

## HIGH

### 1) Line numbers are inconsistent (0-based vs 1-based)
- **What**: Errors reported with `self.current` and column 0 or line 0; wrong caret position or no source line.
- **Refs**: `src/parser.zig:3299`, `src/parser.zig:848`, `src/errors.zig:128`
- **Bad input**:
  ```
  ~run()
  | done |> @as(i32, 1)
  ```
- **Current error**: Points to line 0 or previous line.
- **Should say**: Line 2, column at `@as`.

## MEDIUM

### 1) Zig-code heuristic false positives for valid event names
- **What**: `looksLikeZigCode` flags `std.log` and `log_debug` anywhere in the invocation.
- **Refs**: `src/parser.zig:3144`, `src/parser.zig:3299`
- **Bad input**:
  ```
  ~event std.log { msg: []const u8 }
  | done {}
  
  ~std.log(msg: "hi")
  | done |> _
  ```
- **Current error**: `Zig code not allowed in flows`.
- **Should say**: No error, or a specific “reserved name” diagnostic if this is disallowed by design.

### 2) Phantom type detection grabs the first '[' anywhere
- **What**: `parseSourcePhantomType` scans for `[` anywhere, so array literals/types can be mistaken as phantom annotations.
- **Refs**: `src/parser.zig:4162`
- **Bad input**:
  ```
  ~render(data: [1, 2, 3]) { ... }
  ```
- **Current error**: Invocation mangled or parse error.
- **Should say**: Parse as normal args; only treat `[Type]` immediately before `{` as phantom annotation.

### 3) Multi-line invocation/source-arg parsing ignores brace depth
- **What**: `parseMultiLineInvocation` / `parseFlowAstOrSourceArg` look for a raw `}` and do not report missing `}`. Nested braces or `}` in strings can terminate early.
- **Refs**: `src/parser.zig:3185`, `src/parser.zig:3243`
- **Bad input**:
  ```
  ~foo {
    source: {
      line: "}"
    }
  }
  ```
- **Current error**: Silent truncation or malformed args without a clear error.
- **Should say**: `parse error: unclosed source block` (line/column).

### 4) Inline flow branch coverage uses no-reporter path
- **What**: `checkBranchCoverage` returns `false` without emitting details; user only sees `IncompleteBranchCoverage`.
- **Refs**: `src/shape_checker.zig:1168`, `src/shape_checker.zig:107`
- **Bad input**:
  ```
  ~proc p {
    ~some.event()
    | ok _ |> _
  }
  ```
- **Current error**: Generic `Incomplete branch coverage`.
- **Should say**: `branch 'err' must be handled` with line/column.

### 5) Unknown events in flows return without reporter details
- **What**: `validateFlow` returns `error.UnknownEvent` without adding an error; compiler emits a generic failure.
- **Refs**: `src/shape_checker.zig:527`, `koru_std/compiler.kz:1764`
- **Bad input**:
  ```
  ~missing()
  | done |> _
  ```
- **Current error**: Generic `Unknown event referenced`.
- **Should say**: `unknown event 'missing'` with line/column and maybe nearest match.

## LOW

### 1) ShapeChecker leaks event declarations
- **What**: `ShapeChecker.deinit` intentionally skips freeing event declarations due to allocator ownership mismatch.
- **Refs**: `src/shape_checker.zig:39`
- **Impact**: ~46 small leaks per compile (documented).

### 2) Comptime parser service drops detailed parse errors
- **What**: `parse` in `compiler.kz` returns a generic parse error message instead of reporter errors.
- **Refs**: `koru_std/compiler.kz:1362`

## Open Questions
- Are names like `std.log` intended to be valid event paths? If yes, the Zig-code heuristic needs tightening; if no, emit a targeted reserved-name error.

