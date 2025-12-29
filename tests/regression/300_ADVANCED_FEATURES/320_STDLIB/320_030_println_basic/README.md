# Test 320_030: println_basic

## Purpose
Tests `~std.io:print.ln` - the zero-cost comptime transform for string interpolation.

## Syntax
```koru
~std.io:print.ln("Hello, ${name:s}! The answer is ${value:d}.")
```

Format specifiers:
- `:s` - strings (`[]const u8`)
- `:d` - integers and floats
- `:x` - hexadecimal
- `:any` - any type (default if omitted)

## How It Works
`print.ln` is a `[keyword|comptime|transform]` event that:
1. Parses `${...}` placeholders from the Expression string
2. Extracts variable names and format specifiers
3. Generates inline Zig `std.debug.print` code
4. Replaces the flow with `inline_body` (no runtime event overhead)

## Documentation
See blog post: `/finally-print` on korulang.org

---

## REGRESSION STATUS

**Last passing:** Dec 6, 2025 @ 14:31 (snapshot `2025-12-06T14-31-00.json`)

**First failing:** Dec 6, 2025 @ 23:17 (snapshot `2025-12-06T23-17-25.json`)

### Suspected commits (in breaking window):
```
803478c fix: parser now handles |> followed by newline with step on next line
afa6891 chore: complete FlowAST removal from compiler
434fc36 chore: remove FlowAST aspirational code - it never worked
```

### Current error:
```
DEBUG validateFlow: event='std.io:print.ln', super_shape=false
DEBUG: Checking branch coverage for event 'std.io:print.ln', 1 event branches, 0 flow continuations
DEBUG:   Event branch: 'transformed'
ERROR: Branch 'transformed' must be handled but no continuation found
DEBUG: Branch coverage INCOMPLETE!
```

### Analysis
The shape checker is requiring branch coverage for `| transformed`, but `print.ln` is a
`[transform]` event - it gets replaced with `inline_body` at compile time and should NOT
require runtime branch handling.

Possible causes:
1. FlowAST removal may have affected how transforms are processed
2. Shape checker may not be recognizing `[transform]` annotation
3. Transform may not be running before shape checker validates branches
