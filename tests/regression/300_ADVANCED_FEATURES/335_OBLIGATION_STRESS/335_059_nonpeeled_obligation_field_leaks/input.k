// A destructure may drop plain fields, never an obligation field it cannot
// name. Peeling only original_size leaves data under the unreachable `_.data`
// key; the arm must refuse the dropped debt instead of letting runtime leak
// checking be the only witness.
import std/io
import std/compress

std/compress:gzip(data: "hello koru")
| error e |> std/io:print.ln("ERR {{ e:s }}")
| compressed { original_size }
    |> std/io:print.ln("{{ original_size:d }}")
