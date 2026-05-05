# embedded_blinky results — 2026-05-04T14-41-35

Target: `thumbv7em-none-eabihf` (STM32F401RE / Cortex-M4F)

| Implementation        | format     | .text | .data | .bss | on-disk |
|-----------------------|------------|------:|------:|-----:|--------:|
| c_bare                | thumbv7em  |    94 |    28 |    0 |    5080 |
| zig_freestanding      | thumbv7em  |    98 |     0 |    0 |   66112 |
| rust_naive            | thumbv7em  |   704 |     0 |    4 |    1748 |
| rust_embassy          | —        |   — |   — |  — |     — |
| koru                  | native     |   — |   — |  — |   50048 |

**Notes:**
- `thumbv7em` rows are the apples-to-apples cross-compiled comparison.
- `native` rows compiled to host architecture (no cross-compile threading
  for that toolchain yet) — included for context, not for the headline.
