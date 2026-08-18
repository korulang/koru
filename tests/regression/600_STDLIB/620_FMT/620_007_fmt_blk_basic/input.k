// PIN: `std/fmt:fmt.blk` allocates a formatted string and yields it on
// `| formatted f`. Twin of 620_001 (`ln`, thread-local buffer); this is the
// form that can hold more than that buffer — HTML, JSON, a file. The buffer
// carries `allocated!`; auto-discharge inserts `std/io:free` (335_042).
// The transform rewrites to `fmt.blk.impl` (`-> string<std.io:allocated!>`,
// the same debt `std/io:free` discharges) and breaks to `__KORU_INLINE__`.
// A dangling `:__blk` or a missing impl return type is this test red.
import std/fmt
import std/io

const {
    name: "World"
    count: 42
}

std/fmt:fmt.blk {
    Hello, {{ name:s }}! The answer is {{ count:d }}.
}
| formatted f |> std/io:print.ln("{{ f:s }}")
