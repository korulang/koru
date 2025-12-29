# 100: Parser & AST

This category defines the structure of the Koru Abstract Syntax Tree (AST) and the parsing rules.

## AST Overview

Koru's AST is designed for direct mapping to Zig structures while maintaining event-driven semantics.

### Key Nodes
- **Events**: `~event Path { input } | branch { payload }`
- **Procs**: Verbatim Zig blocks mapped to event namespaces.
- **Flows**: Decision trees of continuations and pipeline steps.
- **Subflows**: Fractal, reusable flow fragments.

## Shape Contracts
The parser captures enough metadata to perform **structural shape checking** before emission. Every event call validates that its input shape matches the current payload and that all output branches are handled.
