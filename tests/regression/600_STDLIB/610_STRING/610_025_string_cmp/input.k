// std/string:cmp — three-way byte-lexicographic order over raw slices.
// The tor 820_007 spelled by hand for its alphabetical tie-break: a bare
// `a < b` on strings does not lower (Zig refuses `<` on []u8 at Stage D),
// so ordering lives on the namespaced surface. | lt | eq | gt — the
// std/num:cmp shape; shorter-prefix-first settles equality through the
// shared prefix. Pure-Koru subflow: recursion over the bytes, no host call.
import std/io
import std/string

tor show { a: string, b: string }
show = std/string:cmp(a, b)
    | lt |> std/io:print.ln("{{ a:s }} lt {{ b:s }}")
    | eq |> std/io:print.ln("{{ a:s }} eq {{ b:s }}")
    | gt |> std/io:print.ln("{{ a:s }} gt {{ b:s }}")

show(a: "ant", b: "bee")
show(a: "cat", b: "cat")
show(a: "dog", b: "bee")
show(a: "app", b: "apple")
show(a: "apple", b: "app")
show(a: "", b: "a")
show(a: "", b: "")
show(a: "Zebra", b: "apple")
