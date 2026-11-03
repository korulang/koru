// 820_003 access_log — read a web access log, aggregate it, print a report.
// PINS group-by-key record processing spelled the way it should read: each
// line destructured by regex named groups, global totals folded into a
// singleton store, per-endpoint rows owned by a std/store whose owned-string
// column keeps the path, and first-seen dedup answered by a std/string-map
// from path to row handle. The report is a store sweep in join order.
import std/io
import std/fs
import std/regex
import std/string
import std/string-map
import std/store

std/store:new(totals) { req: 0[i64], bytes: 0[i64], errs: 0[i64], posts: 0[i64] }
std/store:new(eps, capacity: 16) { label: *std/string:String<std/string:instance!>, hits: i64, bytes: i64 }

std/string-map:new()
| map idx |> std/fs:read-lines(path: "tests/regression/820_DEMONSTRATIONS/820_003_access_log/input.txt")
    ! line l |> std/regex:match(l)
        | `(?<m>[A-Z]+) (?<p>[a-z/]+) (?<st>[0-9]+) (?<by>[0-9]+)` { m, p, st: i64, by: i64 }
            |> std/store:stored {
                totals.req: totals.req + 1,
                totals.bytes: totals.bytes + by,
                totals.errs: totals.errs + @intFromBool(st >= 500),
                totals.posts: totals.posts + @intFromBool(m == "POST")
            }
            |> std/string-map:get(m: idx, k: p)
                | value r |> std/store:stored { eps[r].hits: eps[r].hits + 1 } |> std/store:stored { eps[r].bytes: eps[r].bytes + by }
                | missing |> std/string:from-page(text: p)
                    | ok s |> std/string:take(s): own |> std/store:insert(eps) { label: own, hits: 1, bytes: by }
                        | row r |> std/string-map:set(m: idx, k: p, v: r)
                        | full |> std/io:print.ln("endpoint table full")
                    | err _ |> _
        | no-match |> std/io:print.ln("BAD LINE {{ l:s }}")
    | done _ |> std/string-map:free(m: idx)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")

std/io:print.ln("requests {{ totals.req:d }} bytes {{ totals.bytes:d }} errors {{ totals.errs:d }} posts {{ totals.posts:d }}")

std/store:query(eps)
! query e |> std/io:print.ln("endpoint {{ e.label:S }} hits {{ e.hits:d }} bytes {{ e.bytes:d }}")
