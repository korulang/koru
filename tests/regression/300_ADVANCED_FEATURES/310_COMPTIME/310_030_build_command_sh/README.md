# Test 640: build:command.sh - Frontend Shell Command Execution

## Purpose

Tests the `build:command.sh` feature, which allows instant execution of shell commands without backend compilation overhead. This is a **frontend optimization** that makes common build tasks instant.

## What It Tests

1. **Basic command execution**: `koruc input.kz hello` executes the "hello" command
2. **Argument forwarding**: `koruc input.kz args one two` passes arguments to the shell script
3. **Module-qualified syntax**: Commands use `~std.build:command.sh(...)` syntax

## Design Pattern

Unlike most compiler features, `build:command.sh` is processed in the **frontend** (koruc binary) rather than the backend compiler. This trade-off:

- ✅ Makes commands instant (no backend compilation)
- ✅ Enables fast development iteration
- ⚠️  Breaks the "programmable pipeline" pattern slightly
- 📝 Is clearly documented as a pragmatic optimization

For commands that need Zig/Koru compilation, use `build:command.proc` or `build:command.flow` (backend passes).

## Expected Output

```
=== Testing shell command 'hello' ===
Hello from Koru!

=== Testing shell command 'args' with arguments ===
Args: one two three
```

## Related

- `build:requires` - Build dependencies (backend pass)
- `flag.declare` - Compiler flags (frontend collection pattern this follows)
