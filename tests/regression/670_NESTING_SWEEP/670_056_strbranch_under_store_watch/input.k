// NESTING SWEEP — strbranch nested UNDER a store-watch arm (position 6:
// a context the 5-construct/6-position grid doesn't cover, since a store
// watch's body is SPLICED to the store's write sites, not run at its
// lexical position (690_046's "transplant purity" model), rather than
// merely running inline like the effect/for-each/capture positions.
//
// The nested `| ok s` obligation branch discharges its own view (mirrors
// 670_050's flow-head baseline exactly) and additionally reads the watch
// arm's own payload binding `x` from one level of nesting deeper than
// 690_046's fix reaches (that fix threads scope for a flat mid-chain pipe
// bind; this pins the same allowed-name propagation into a NESTED branch
// body). `x` is the arm's own top-level payload, introduced inside the
// arm — not ambient state from outside it (contrast 690_006, which stays
// rejected because its name IS bound outside the arm).
import std/io
import std/store
import std/string

std/store:new(c) { v: 0[i64] }

std/store:watch(c)
! v x |> std/string:from-page(text: "x")
    | ok s |> std/io:print.ln("ok x={{ x:d }}") |> std/string:free(s)
    | err _ |> std/io:print.ln("err")

std/store:stored { c.v: 1 }
