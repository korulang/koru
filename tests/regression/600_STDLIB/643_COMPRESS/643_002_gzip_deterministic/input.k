// Pins encoder determinism and the cached-tree path: two sequential gzip
// calls on identically-shaped bodies must emit byte-identical streams —
// the second call reuses the first's Huffman tree under the used-symbol
// coverage guard, and the emitted block is still a valid full encoding of
// the input. A drift in the cache machinery (stale tree, missing symbol,
// ordering bug) flips either the equality or the checksum.

import std/io
import std/compress

std/compress:gzip(data: "{\"route\":\"/json/25\",\"items\":[1,2,3],\"total\":6}")
| error e |> std/io:print.ln("ERR {{ e:s }}")
| compressed c1 |> std/compress:crc32(c1.data): crc1
    |> std/compress:gzip(data: "{\"route\":\"/json/25\",\"items\":[1,2,3],\"total\":6}")
    | error e2 |> std/io:print.ln("ERR2 {{ e2:s }}")
    | compressed c2 |> std/compress:crc32(c2.data): crc2
        |> if(c1.data.len == c2.data.len and crc1 == crc2)
            | then |> std/io:print.ln("deterministic {{ c1.data.len:d }} crc={{ crc1:d }}")
                |> std/io:free(content: c1.data) |> std/io:free(content: c2.data)
            | else |> std/io:print.ln("NONDETERMINISTIC {{ c1.data.len:d }}/{{ c2.data.len:d }} {{ crc1:d }}/{{ crc2:d }}")
                |> std/io:free(content: c1.data) |> std/io:free(content: c2.data)
