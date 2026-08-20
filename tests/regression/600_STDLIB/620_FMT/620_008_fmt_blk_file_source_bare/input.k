// PIN: `std/fmt:fmt.blk @"path"` — the BARE file-source form, the file twin
// of the inline `{` block (620_007). The template text lives in an external
// file read at compile time; `: f` binds the formatted result and the inline
// `|>` continues it — the same grammar as the block-close `}: f |> …`.
// The emitted backend carries `source from file 'banner.txt'`.
import std/fmt
import std/io

const {
    name: "World"
    count: 42
}

std/fmt:fmt.blk @"banner.txt": f |> std/io:print.ln("{{ f:s }}")
