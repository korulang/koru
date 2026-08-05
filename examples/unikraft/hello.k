// Pure Koru. No tilde, no Zig, no interpolation — so this goes down print.blk's
// raw path (raw_io_prefix / __kz_w), the fourth write site.

import std/io

std/io:print.blk {
    Hello from pure Koru, inside a unikernel
}
