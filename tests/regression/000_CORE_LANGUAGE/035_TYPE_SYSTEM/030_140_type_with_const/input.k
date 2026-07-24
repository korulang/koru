// Pins the registry integration for `const`:
// `const` REGISTERS its symbols (name -> type-ref + comptime value)
// into the registry's symbols table instead of only splicing text —
// the "const doesn't store its symbols" gap named by Lars 2026-07-06.
// The observable here is still just the value flowing; the pin's
// comment carries the registration intent until a query surface
// exists to assert it directly (see 340_007).

import std/types
import std/io

std/types:struct(Config) {
    value: i64,
    enabled: bool,
}

const { threshold: 42 }

std/io:print.ln("Value: {{ threshold:d }}")
