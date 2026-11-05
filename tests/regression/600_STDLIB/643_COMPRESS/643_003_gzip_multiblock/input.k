// Pins multi-block: std/compress:gzip chunks input past BLOCK_CAP (65535 —
// the token buffer's bound) into multiple DEFLATE blocks, BFINAL set only
// on the last. Positions stay absolute across blocks so the 32KB match
// window reaches back across boundaries. input.txt is 69,624 bytes of
// repeated-key JSON — two blocks of output. The stream CRC pins the exact
// emitted bytes.

import std/io
import std/compress

std/io:read-file(path: "tests/regression/600_STDLIB/643_COMPRESS/643_003_gzip_multiblock/input.txt")
| not-found |> std/io:print.ln("fixture missing")
| failed e |> std/io:print.ln("read failed {{ e:s }}")
| ok content |> std/compress:gzip(data: content)
    | error e2 |> std/io:print.ln("ERR {{ e2:s }}") |> std/io:free(content)
    | compressed c |> std/compress:crc32(c.data): crc
        |> std/io:print.ln("multi {{ c.original_size:d }}->{{ c.data.len:d }} crc={{ crc:d }}")
        |> std/io:free(content) |> std/io:free(content: c.data)
