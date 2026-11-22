// 230_035: `.location` literals in backend_output_emitted.zig must escape
// backslashes. emitInvocationMetaFields wrote `loc.file` raw into a Zig
// string literal — on a Windows host the absolute path arrives as
// `W:\src\...` and the emitted file cannot parse (`\s`, `\k` are not Zig
// escapes). post.sh pins the literal shape: any `\` inside a .file literal
// must be part of a `\\` pair. Vacuous on POSIX (no backslashes in paths);
// on Windows the backend build itself would refuse first — this names it.

import std/io

std/io:print.blk {
    loc file literal pin
}
