// std/yaml — the DOM-over-events assembly the yq assay recommended:
// libyaml events stream into std.json.Value nodes in an arena, so a
// parsed YAML document IS a json-dom document — `dom.root`/`val`/`at`/
// `each`/`render`/`free` all work unmodified. `std/yaml:emit` writes
// block YAML back out through the same `string<emitted!>` obligation
// `emit.free` discharges. `! doc` fires per document in the stream —
// multi-doc input yields one `<open!>` handle per document.
import std/io
import std/json
import std/yaml

std/yaml:parse(input: "name: ada\nage: 36\nratio: 1.5\nflag: true\nnothing: ~\ntags:\n  - x\n  - y\nmeta:\n  lang: koru\n")
! doc d |> std/json:dom.root(doc: d): r
    |> std/json:dom.each(n: r)
        ! field f |> std/io:print.ln("key {{ f.key:s }}")
        ! item _ |> _
        | done n |> std/io:print.ln("fields={{ n:d }}")
    |> std/json:dom.at(n: r, key: "name")
        | found f |> std/json:dom.val(n: f)
            | str s |> std/io:print.ln("name={{ s:s }}")
            | object _ |> _
            | array _ |> _
            | numstr _ |> _
            | int _ |> _
            | float _ |> _
            | bool _ |> _
            | null |> _
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.at(n: r, key: "age")
        | found f |> std/json:dom.val(n: f)
            | int i |> std/io:print.ln("age={{ i:d }}")
            | object _ |> _
            | array _ |> _
            | str _ |> _
            | numstr _ |> _
            | float _ |> _
            | bool _ |> _
            | null |> _
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.at(n: r, key: "tags")
        | found t |> std/json:dom.each(n: t)
            ! field _ |> _
            ! item el |> std/json:dom.val(n: el)
                | str s |> std/io:print.ln("tag {{ s:s }}")
                | object _ |> _
                | array _ |> _
                | numstr _ |> _
                | int _ |> _
                | float _ |> _
                | bool _ |> _
                | null |> _
            | done n |> std/io:print.ln("tags={{ n:d }}")
        | not-found |> _
        | wrong-kind |> _
    |> std/json:dom.render(n: r): js |> std/io:print.ln("{{ js:s }}")
        |> std/json:emit.free(text: js)
    |> std/yaml:emit(n: r): out |> std/io:print.ln("{{ out:s }}")
        |> std/json:emit.free(text: out)
    |> std/json:dom.free(doc: d)
| done n |> std/io:print.ln("docs={{ n:d }}")
| malformed m |> std/io:print.ln("BAD {{ m:s }}") |> std/io:free(content: m)
