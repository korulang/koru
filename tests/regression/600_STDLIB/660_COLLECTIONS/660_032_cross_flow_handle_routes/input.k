// A proto-container handle passed BETWEEN flows routes by its declared type.
// `my-len` takes `xs: *List_Engine<list>` and calls `std/list:len(xs)` — no
// `new` site in its own flow. The op tor resolves `Engine` from the tor
// parameter (location-anchored, order-proof: the tor textually precedes the
// `new` site) and rewrites to `len-Engine`. Before op routing this refused
// with KORU030 against the i64 trunk (`expected *List_i64<list>`).
// Prints len=0, exit 0.
import std/io
import std/list
import std/types

std/types:proto(Engine) {
    rpm: i32
}

tor my-len { xs: *List_Engine<list> } -> usize
my-len = std/list:len(xs): n -> n

std/list:new(Engine)
| list xs |> my-len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
