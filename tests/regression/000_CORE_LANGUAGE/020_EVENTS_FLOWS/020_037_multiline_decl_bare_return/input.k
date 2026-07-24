// A MULTI-LINE event decl carries its bare return on the closing-brace line:
// `}\n` was silently eating `-> T` (the shape parser dropped everything after
// the close), so a multi-line `-> SiteResult` transformer decl lost its return
// type without a trace — surfaced by the single-return std migration (210_131).
// The single-line twin is 020_033; this pins the split-line form.
import std/io

tor pick {
    n: i64
} -> i64

pick = if(n < 10)
| then -> n
| else -> n - 10

pick(n: 21): a |> std/io:print.ln("{{ a:d }}")
pick(n: 3): b |> std/io:print.ln("{{ b:d }}")
