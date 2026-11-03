// 820_007 top_words — the top-N word frequency report: `uniq -c | sort -rn
// | head`. 820_004 proved the counting half and named the frontier that
// stopped top-N: string-map had no iteration. std/string-map:each(m)
// ! pair { k, v } closes it — this is the follow-through proof.
//
// Pipeline: read-lines streams the text, regex:scan [a-z]+ fires once per
// word, counts fold into a string-map. each drains the map pair by pair;
// k is a borrow into the table's owned key bytes, so every row of the
// `ranked` store copies its word into an owned *String<instance!> — custody
// moves in on insert. Hash order is declared unstable, so the report
// imposes a total order by repeated max-extraction: `pick` sweeps ranked
// keeping (count desc, word lexicographic), `report` takes the winner row —
// the item carries the owned word out, it prints, free discharges. `top`
// recurses N times.
//
// Ordering rides `std/string:cmp` — the three-way byte-lexicographic tor
// (| lt | eq | gt) the stdlib grew for exactly this tie-break; a bare
// string `<` still does not lower (backend refuses `<` on []u8).
import std/io
import std/fs
import std/regex
import std/string
import std/string-map
import std/store

std/store:new(ranked, capacity: 64) { word: *std/string:String<std/string:instance!>, cnt: i64 }
std/store:new(best) { row: 0[i64], cnt: 0[i64] }

// Sweep ranked; leave the winning row's handle and count in `best`
// (best.row == -1 when the store is empty). Order: count desc, then
// lexicographic on the word — a total order, so the report never leans
// on the map's unstable hash iteration order.
tor pick {}
pick = std/store:stored { best.row: -1, best.cnt: -1 }
    |> std/store:query(ranked)
        ! query e |> if(best.row == -1)
            | then |> std/store:stored { best.row: e, best.cnt: e.cnt }
            | else |> if(e.cnt > best.cnt)
                | then |> std/store:stored { best.row: e, best.cnt: e.cnt }
                | else |> if(e.cnt == best.cnt)
                    | then |> std/string:cmp(a: e.word.data, b: ranked[best.row].word.data)
                        | lt |> std/store:stored { best.row: e, best.cnt: e.cnt }
                        | eq |> _
                        | gt |> _

// Take the winning row; `| item` carries the row's fields out including
// the owned word — print, then free discharges the instance obligation.
tor report { rank: i64 }
report = std/store:take(ranked[best.row])
    | item it |> std/io:print.ln("{{ rank:d }}. {{ it.word:S }} {{ it.cnt:d }}")
        |> std/string:free(s: it.word)

// Extract-and-report up to `left` winners; returns how many printed —
// stops early when the store drains, the head(1) behavior on a short
// corpus.
tor top { left: i64, rank: i64 } -> i64
top = pick() |> if(best.row == -1)
    | then -> 0
    | else |> report(rank) |> if(left <= 1)
        | then -> 1
        | else |> top(left: left - 1, rank: rank + 1): n -> 1 + n

std/string-map:new()
| map m |> capture { words: 0[i64] }
    ! as acc |> std/fs:read-lines(path: "tests/regression/820_DEMONSTRATIONS/820_007_top_words/input.txt")
        ! line l |> std/regex:scan(input: l)
            ! `[a-z]+` w |> std/string-map:get(m, k: w)
                | value c |> std/string-map:set(m, k: w, v: c + 1) |> captured { words: acc.words + 1 }
                | missing |> std/string-map:set(m, k: w, v: 1) |> captured { words: acc.words + 1 }
        | failed e |> std/io:print.ln("FAILED {{ e:s }}")
    | captured t |> std/io:print.ln("words {{ t.words:d }}")
        |> std/string-map:each(m)
            ! pair { k, v } |> std/string:from-page(text: k)
                | ok s |> std/string:take(s): own |> std/store:insert(ranked) { word: own, cnt: v }
                    | row _ |> _
                    | full |> std/io:print.ln("ranked full")
                | err _ |> _
            | done n |> std/io:print.ln("distinct {{ n:d }}") |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")

std/io:print.ln("top 5:")
top(left: 5, rank: 1): shown
|> std/io:print.ln("{{ shown:d }} shown")
