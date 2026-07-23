// Owned-store `| full` give-back (690_011's sibling): insert into a full
// owned-string store reissues column ownership on `| full` so the caller
// can free — no silent leak, no panic. Capacity 2; third insert hits full.
import std/io
import std/string
import std/store

std/store:new(todos, capacity: 2) {
    label: *std/string:String<std/string:instance!>,
    done: i64
}

std/string:from-page(text: "a")
| ok a |> std/string:take(s: a): m |> std/store:insert(todos) { label: m, done: 0 }
    | row _ |> std/string:from-page(text: "b")
        | ok b |> std/string:take(s: b): n |> std/store:insert(todos) { label: n, done: 0 }
            | row _ |> std/string:from-page(text: "c")
                | ok c |> std/string:take(s: c): p |> std/store:insert(todos) { label: p, done: 0 }
                    | row _ |> std/io:print.ln("ok")
                    | full f |> std/string:free(s: f.label) |> std/io:print.ln("full")
                | err _ |> _
            | full _ |> std/io:print.ln("unexpected-full-2")
        | err _ |> _
    | full _ |> std/io:print.ln("unexpected-full-1")
| err _ |> _
