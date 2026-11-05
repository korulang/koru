// `| compressed { data }` peels the record's fields onto scalar bindings —
// the field's obligation rides the LOCAL name (`data`), so io:free can
// consume it. Before the remap the debt sat under the discard key `_.data`:
// free saw "no live obligation" and the allocation only ever surfaced in
// the runtime leak counter.
import std/io
import std/compress

std/compress:gzip(data: "hello koru")
| error e |> std/io:print.ln("ERR {{ e:s }}")
| compressed { data }
    |> std/io:print.ln("{{ data.len:d }}")
    |> std/io:free(content: data)
