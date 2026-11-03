// Word-frequency report over a fixed text file — the 820 proof-catalog's
// text-statistics entry. `std/fs:read-lines` streams the file line by line;
// inside each `! line`, `std/regex:scan` `[a-z]+` fires once per word
// (punctuation is never a token). Each word folds into a `std/string-map`
// count via get/set; a `capture` folds the running word total alongside.
// The map's `<map!>` obligation lives across both nested effect streams and
// discharges at `free` in the report's `| done`. The report reuses scan to
// enumerate the tracked vocabulary in order — `| missing` prints a real 0
// for a tracked word the text never uses.
import std/io
import std/fs
import std/regex
import std/string-map

std/string-map:new()
| map m |> capture { words: 0[i64] }
    ! as acc |> std/fs:read-lines(path: "tests/regression/820_DEMONSTRATIONS/820_004_word_frequency/input.txt")
        ! line l |> std/regex:scan(input: l)
            ! `[a-z]+` w |> std/string-map:get(m, k: w)
                | value c |> std/string-map:set(m, k: w, v: c + 1) |> captured { words: acc.words + 1 }
                | missing |> std/string-map:set(m, k: w, v: 1) |> captured { words: acc.words + 1 }
        | done _ |> _
        | failed e |> std/io:print.ln("FAILED {{ e:s }}")
    | captured t |> std/io:print.ln("words: {{ t.words:d }}")
        |> std/string-map:count(m): n |> std/io:print.ln("distinct: {{ n:d }}")
        |> std/regex:scan(input: "the of a it and is in to")
            ! `[a-z]+` w |> std/string-map:get(m, k: w)
                | value v |> std/io:print.ln("{{ w:s }}: {{ v:d }}")
                | missing |> std/io:print.ln("{{ w:s }}: 0")
            | done |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
