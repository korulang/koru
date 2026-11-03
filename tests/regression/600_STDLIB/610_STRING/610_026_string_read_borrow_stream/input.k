// std/string:read — the *String -> string read-out leaf. Produced text
// lends its bytes to `! text` as an unqualified `string` for the call's
// duration: `for` iterates it, `split` pieces it — the fmt.blk +
// split("") bridge (820_008) and the detach read-out (whose owned slice
// no leaf can dispose — a runtime leak) both retire here. The borrow is
// down-only: the String keeps its own lifetime, freed explicitly below.
// (`for` yields u8 on zig, char on cs — count the bytes through the
// store rather than formatting one.)
import std/io
import std/string
import std/store

std/store:new(count) { n: 0[i64] }

std/string:from-page(text: "a b")
| ok s |> std/string:take(s): m |> std/string:append(s: m, text: " c")
    | ok |> std/string:read(s: m)
        ! text t |> std/string:split(s: t, sep: " ")
            ! piece p |> std/io:print.ln("piece {{ p:s }}")
            | done n |> std/io:print.ln("pieces={{ n:d }}")
                |> for(t)
                    ! each _ |> std/store:stored { count.n: count.n + 1 }
        | done l |> std/io:print.ln("len={{ l:d }}") |> std/io:print.ln("bytes={{ count.n:d }}")
            |> std/string:free(s: m)
    | err _ |> _
| err _ |> _
