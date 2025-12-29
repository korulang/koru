# 200: Compiler Features & Zig Emission

This category covers the lowering of Koru constructs to plain, optimal Zig code.

## Emission Strategy: Zero Runtime
Koru has NO runtime. It lowers directly to:
1. **Namespaced Structs**: Dotted paths `a.b.c` become nested `const struct` declarations.
2. **Handlers**: Procs become `pub fn handler(e: Input) Output`.
3. **Unions**: Event branches become `union(enum)` types.
4. **Switches**: Flow continuations lower to Zig `switch` statements on union tags.

## Naming Convention
- `Input`: Payload structure for an event.
- `Output`: Union of all possible branches for an event.
- `__koru_flow_*`: Generated local functions for flow execution.
