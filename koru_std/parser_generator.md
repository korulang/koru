# Parser Generator Vision

## Current State
Basic lexer generation from event schemas with phantom regex patterns:
```koru
~[derive(parser)]event token {}
| number u64[\d+]
| plus void[\+]
```

## Future Vision
Full parser generation with grammar rules, enabling custom DSLs via Source blocks:
```koru
~[derive(parser)]event expr {}
| add { left: Expr, right: Expr }
| num u64[\d+]

~parse.expr [expr] {
    1 + (2 + 3)
}
| add e |> ...
```

## Implementation Notes
- Use external regex library via `compiler:requires` (PCRE, etc.)
- Phantom types carry patterns - derive handler interprets them
- Generated parser integrates with Source blocks for compile-time DSL parsing
- Metacircular flex: Koru parsing Koru-defined grammars
