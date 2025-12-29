# 300: Advanced Features

This category covers high-level abstractions like Subflows, Comptime integration, and the Kernel DSL.

## The Fractal Heart: Subflows
**Koru** means "coil" or "spiral," representing a fractal nature. The core abstraction is the **subflow**:
- A program is a subflow.
- Branch constructors are tiny, anonymous subflows.
- Everything follows the same pattern: **input → transformation → output**.

## Design Rule: Flows vs Procs
- **Flows do Plumbing**: Shape transformation and routing.
- **Procs do Computation**: Data transformation and logic.

Subflows enable complex composition while keeping the underlying Zig code readable and efficient.
