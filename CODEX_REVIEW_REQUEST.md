# Codex Review Request

## What We Want

A brutal audit. Two categories:

### 1. DX / Error Messages

Find every way a user could write almost-valid Koru and get a confusing error message.

- **Syntax errors that slip to backend** - Things the parser accepts but Zig rejects with cryptic errors
- **Missing helpful suggestions** - Places where we could say "did you mean X?"
- **Confusing error messages** - Where the error points to the wrong line or says the wrong thing
- **Common mistakes from other languages** - Python/JS/Rust habits that break in Koru

### 2. General Code Quality

- **Obvious bugs** - Logic errors, off-by-ones, missing checks
- **Dead code** - Unused functions, unreachable branches
- **Inconsistencies** - Similar things handled differently
- **Performance issues** - Obvious inefficiencies
- **Memory issues** - Leaks, use-after-free patterns

## Key Files

- `src/parser.zig` - Frontend parser
- `src/shape_checker.zig` - Structural validation
- `src/emitter.zig` - Code generation
- `koru_std/compiler.kz` - Backend coordination

## Format

Prioritized list:
- **CRITICAL**: Users will hit this constantly / definite bug
- **HIGH**: Common mistake / likely bug
- **MEDIUM**: Less common / code smell
- **LOW**: Edge case / nitpick

For DX issues, show:
1. The bad input
2. Current error (if any)
3. What the error SHOULD say

Be harsh.
