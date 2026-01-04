# Literate Annotations

## Vision

Annotation blocks become micro-documents that explain AND instruct:

```koru
~[
# Token Grammar

Defines a lexer for arithmetic expressions.

- derive(parser)
- optimize(level: 3)

## Whitespace Handling

Skip whitespace tokens to keep the stream clean.

- whitespace(skip)
] event token {}
```

## Syntax Rules

1. **`#` lines** - Markdown headings (documentation)
2. **`- ` lines** - Directives (with space after dash, like markdown lists)
3. **Plain text** - Prose documentation
4. **Empty lines** - Preserved for readability

## Parser Behavior

Parser stores EVERYTHING as opaque strings. Compile-time code filters:
- Lines starting with `- ` → directives
- Everything else → documentation

## Why This Matters

1. **Documentation lives with directives** - can't drift
2. **Self-documenting metadata** - explains intent AND instruction
3. **AI-friendly** - prose gives context for directives
4. **Markdown-native** - developers already know the syntax

## Implementation

Parser changes needed:
- Support `- ` (space after dash) as directive prefix
- Store full annotation block including prose
- Let compile-time code extract what it needs
