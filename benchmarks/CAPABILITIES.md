# Capability Grid

What each language can do **natively** vs **emulated** vs **not at all** for effect-branch-style abstractions.

## Capabilities

- **A. Single-kind yield** — basic generator (yield one value type, consumer iterates)
- **B. Multi-kind yield** — one producer firing distinct effect kinds with their own typed payloads, no tagged-union flattening required
- **C. Resume values** — consumer's handler returns a value the producer uses (bidirectional yield)
- **D. Composable nesting** — handlers firing events whose handlers fire events, with the runtime cost staying constant per level (no per-level dispatch tax)
- **E. Compile-time specialization** — handler structure known at compile time, direct calls, no vtable/dispatch object
- **F. Zero-allocation per yield** — no heap object per iteration of the consumer loop
- **G. Closed-form reduction** — when the iteration's data flow is legible to the optimizer, the loop reduces to a constant
- **H. Algebraic-effect handler model** — exception-shaped non-local control flow via the same primitive

## Grid

`✓` native | `◐` emulated (non-language-native) | `✗` not practical

| Language | A | B | C | D | E | F | G | H |
|---|---|---|---|---|---|---|---|---|
| **Koru** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| **C# (`yield return`)** | ✓ | ◐ flatten-to-union | ✗ | ✗ | ✗ | ✗ heap state machine | ✗ JIT can't see through | ✗ |
| **JavaScript (`function*`)** | ✓ | ◐ flatten-to-union | ◐ via `.next(value)` | ✗ | ✗ | ✗ heap generator | ✗ | ✗ |
| **Python (`yield`, `.send`)** | ✓ | ◐ flatten-to-union | ✓ via `.send` | ✗ | ✗ | ✗ heap generator | ✗ | ✗ |
| **Rust iterators (stable)** | ✓ | ◐ flatten-to-union | ✗ | ◐ via combinators | ✓ | ✓ | ✓ | ✗ |
| **Rust generators (nightly)** | ✓ | ◐ flatten-to-union | ✗ | ✗ | ✗ heap-backed | ✗ | ✗ | ✗ |
| **OCaml 5 effects** | ✓ | ✓ | ✓ | ✓ | ✗ runtime dispatch | ✗ allocates | ✗ | ✓ |
| **Koka** | ✓ | ✓ | ✓ | ✓ | ◐ optimization-dependent | ◐ | ✗ | ✓ |
| **Zig (manual)** | ◐ hand-written state machine | ◐ tagged union | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **C (manual)** | ◐ hand-written state machine | ◐ tagged union | ✗ | ◐ | ✓ | ✓ | ✓ | ✗ |

The cells are claims to be tested. Test results either confirm or surface the bug.

## How "emulated" rows are reported

When a test requires capability `X` and a language doesn't have `X` natively, we either:

1. **Skip** the language for that test, with a note explaining why.
2. **Include an emulated implementation** with `non-native: <implementation approach>` annotation on the result row.

Headline tests (the ones we publish chart-style) use option 2 so the comparison is "here's what the same intent looks like in N languages" rather than "here's a chart where some languages didn't compete."
