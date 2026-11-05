// The same peel without the discharge: the destructured field's obligation
// is now a named debt — the exit check refuses it, where the discard-keyed
// `_.data` debt used to slip past the compiler and leak at runtime.
import std/io
import std/compress

std/compress:gzip(data: "hello koru")
| error e |> std/io:print.ln("ERR {{ e:s }}")
| compressed { data }
    |> std/io:print.ln("{{ data:s }}")
