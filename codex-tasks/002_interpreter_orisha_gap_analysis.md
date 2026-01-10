# Task 002: Interpreter Gap Analysis for Orisha

## Status
- [ ] Not Started

## Context

Koru is a language with **event continuations** - typed control flow where every branch must be handled. The vision is to use Koru continuation chains as a **wire protocol** for Orisha (web framework), replacing REST/GraphQL.

Instead of sending data and hoping the client handles it correctly, Orisha would send typed continuation chains that the client MUST handle exhaustively.

## The Interpreter

The interpreter (`koru_std/interpreter.kz`) allows runtime parsing and execution of Koru source strings. Key components:

- `~std.interpreter:run` - parse source + execute
- `~std.interpreter:eval` - execute pre-parsed AST (fast path)
- `~std.runtime:register(scope: "name") { events }` - declare which events are available in a scope (Source block as sandbox)
- `~std.runtime:get_scope(name: "...")` - get dispatcher for a scope

## What Orisha Needs

1. **Basic parse + execute** - parse a source string, dispatch, get result
2. **Dynamic scope lookup** - `get_scope(name: ANY_STRING)` - currently hardcoded to only "test"
3. **Multi-event scopes** - scope with multiple events, dispatch routes correctly
4. **Continuation chains** - `~a() | ok x |> b(x.field) | done |> ...` executes fully
5. **Binding propagation** - field access works: `x.name`, `x.id`
6. **Branch constructors** - `| ok |> result { status: 200 }` constructs return values
7. **Runtime conditionals** - `~if(cond) | then |> ... | else |> ...`
8. **Error handling** - parse_error, validation_error, dispatch_error all work

## Known Issues

1. **Hardcoded scope lookup** in `koru_std/runtime.kz:get_scope` - only handles "test" scope:
   ```zig
   if (std.mem.eql(u8, name, "test")) {
       if (@hasDecl(root.main_module, "dispatch_test")) {
           return .{ .scope = .{ .dispatcher = &root.main_module.dispatch_test } };
       }
   }
   ```
   Needs to be dynamic to support arbitrary scope names.

2. **Zig keyword escaping** - when using reserved words like `error` as field names, must use `@"error"` syntax. This is documented in CLAUDE.md Active Gotchas.

3. **Benchmark accuracy unknown** - previous benchmark claims (ranging from "1300x faster than Python" to "5x slower") are unreliable. Need honest benchmarks that measure what they claim to measure.

## Approach: Failing Tests First

Write tests that describe what we WANT, run them, see what fails. That's the gap map. No claims about what works until we see it work.

Test file should go in: `tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_040_interpreter_orisha_requirements/`

## Files to Study

- `/Users/larsde/src/koru/koru_std/interpreter.kz` - main interpreter
- `/Users/larsde/src/koru/koru_std/runtime.kz` - scope registration and lookup
- `/Users/larsde/src/koru/tests/regression/400_RUNTIME_FEATURES/430_RUNTIME/430_026_interpreter_run_event/input.kz` - example of working interpreter test

## For Codex

When writing the gap analysis test:
- Use `@"error"` for Zig reserved keywords as field names
- Each test should print PASS or FAIL explicitly
- Benchmark should measure and print actual numbers, no claims
- Keep tests independent so we can see exactly what works/fails
