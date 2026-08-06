// Pins the raw_posix lowering of print.blk: a call-site `|raw_posix` tag
// selects the inline posix.write emitter instead of the std.debug.print body.
// A literal run goes through the literal writer, `:d` through the hand-coded
// i64 digit writer, `:s` through the slice writer — all inside one emitted
// helper struct. Only `:d`/`:s` specifiers keep the raw path; `:f`/`:any`
// would fall back to the formatting body.

import std/io

const {
    label: "answer"
    count: 42[i32]
}

std/io:print.blk|raw_posix {
    The {{ label:s }} is {{ count:d }}.
}
