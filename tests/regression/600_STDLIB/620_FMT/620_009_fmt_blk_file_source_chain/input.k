// PIN: file source in STEP position — `| done r |> fmt.blk @"path": f |> …`
// is the file twin of the block-carrying chain step (`… |> fmt.blk { … }`,
// ward's dashboard shape). The chain head splits, the terminal reads the file
// at compile time, binds `: f`, and continues inline.
// NOTE: the bare `@"path"` spelling — a typed `<type>"path"` form was dropped
// here deliberately: the source type tag is an open design question (210_024 /
// 210_039, parked) and `fmt.blk` takes untyped `Source`.
import std/fmt
import std/io

const {
    count: 42
}

pub tor query { q: i64 }
! ?ask i64 -> i64
| done i64

query = if(ask)
| then |> ask(q): a => done a
| else => done 0

query(q: 41)
| done r |> std/fmt:fmt.blk @"banner.txt": f |> std/io:print.ln("{{ f:s }}")
