// Koru-native base-type annotations on `const` values.
//
// `count: 42[i32]` pins the literal's base type. The annotation is value-position
// SQUARE brackets `[type]` (unambiguous after a literal, where `<…>` would read as
// less-than); `<phantom>` is the orthogonal type-state feature on TYPES.
//
// The annotation is OPTIONAL and lowers per-target via the two `const` template
// variants: Zig emits `@as(i32, 42)`, JS erases it (`42`). A string literal IS its
// type, and a bare number takes the target default — neither needs an annotation.
import std/io

const {
    name: "Claude"
    count: 42[i32]
    size: 7[u8]
    plain: 100
}

std.io:print.ln("{{ name:s }} {{ count:d }} {{ size:d }} {{ plain:d }}")
