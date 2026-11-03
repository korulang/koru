// 820_006 — kv_protocol: serve a scripted line-protocol session — an AUTH
// gate, SET/GET/DEL/INCR against an owned-string table, QUIT closing the
// connection. The task memcached/redis-cli run against a real server; here
// the client script is a file and every command earns exactly one reply.
//
// Three pieces of structure, all Koru:
//   * `session` — a singleton store row carrying the connection stage
//     (0 anonymous, 1 authed, 2 closed). Every command checks it: KV verbs
//     answer `ERR NOAUTH` until AUTH flips the stage, and once QUIT lands
//     the gate drops each remaining line without a reply, the way a closed
//     socket stops answering.
//   * `kv` — a std/store whose rows OWN their key and value strings
//     (*String<instance!> columns). SET moves custody in on insert and on
//     overwrite (a `stored` write reissues custody and frees the old
//     value); DEL takes the row and the caller frees both fields. The
//     obligations ARE the protocol's memory discipline.
//   * `index` — a std/string-map from key text to row handle, so lookups
//     are by name, not by sweep. DEL parks the entry at -1: row handles
//     are generation-stable across swap-remove (690_092), but a stale
//     handle READ traps — so absence is spelled as a dead handle, and the
//     reader checks the sign before it dereferences.
// Dispatch is one regex match per line — each command is a pattern arm
// whose body is a flow. No proc anywhere in the program.
import std/io
import std/fs
import std/regex
import std/string
import std/string-map
import std/store

std/store:new(session) { stage: 0[i64] }
std/store:new(kv, capacity: 8) { key: *std/string:String<std/string:instance!>, val: *std/string:String<std/string:instance!> }

// Insert a fresh key/value row, index it, and answer with `reply`. Shared
// by SET-miss, DEL-then-SET, and INCR-on-a-missing-key — the three protocol
// paths that all mint a row.
tor put { m: *std/string-map:Map_string_i64<map>, k: string<*@scoped>, v: string<*@scoped>, reply: string<*@scoped> }
put = std/string:from-page(text: k)
| ok sk |> std/string:take(s: sk): okey |> std/string:from-page(text: v)
    | ok sv |> std/string:take(s: sv): oval |> std/store:insert(kv) { key: okey, val: oval }
        | row r |> std/string-map:set(m, k, v: r) |> std/io:print.ln("{{ reply:s }}")
        | full _ |> std/io:print.ln("ERR store full")
    | err _ |> _
| err _ |> _

std/string-map:new()
| map m |> std/fs:read-lines(path: "tests/regression/820_PROOFS/820_006_kv_protocol/input.txt")
    ! line l |> if(session.stage < 2)
        | then |> std/regex:match(l)
            | `PING` _ |> std/io:print.ln("PONG")
            | `AUTH (?<pw>[a-z0-9]+)` { pw } |> if(session.stage == 0)
                | then |> if(pw == "s3cr3t")
                    | then |> std/store:stored { session.stage: 1 } |> std/io:print.ln("OK")
                    | else |> std/io:print.ln("ERR invalid password")
                | else |> std/io:print.ln("ERR already authenticated")
            | `SET (?<k>[a-z_]+) (?<v>.+)` { k, v } |> if(session.stage == 1)
                | then |> std/string-map:get(m, k)
                    | value rv |> if(rv >= 0)
                        | then |> std/string:from-page(text: v)
                            | ok sv |> std/string:take(s: sv): oval |> std/store:stored { kv[rv].val: oval } |> std/io:print.ln("OK")
                            | err _ |> _
                        | else |> put(m, k, v, reply: "OK")
                    | missing |> put(m, k, v, reply: "OK")
                | else |> std/io:print.ln("ERR NOAUTH")
            | `GET (?<k>[a-z_]+)` { k } |> if(session.stage == 1)
                | then |> std/string-map:get(m, k)
                    | value rv |> if(rv >= 0)
                        | then |> std/io:print.ln("\"{{ kv[rv].val:S }}\"")
                        | else |> std/io:print.ln("(nil)")
                    | missing |> std/io:print.ln("(nil)")
                | else |> std/io:print.ln("ERR NOAUTH")
            | `DEL (?<k>[a-z_]+)` { k } |> if(session.stage == 1)
                | then |> std/string-map:get(m, k)
                    | value rv |> if(rv >= 0)
                        | then |> std/store:take(kv[rv])
                            | item t |> std/string:free(s: t.key) |> std/string:free(s: t.val)
                                |> std/string-map:set(m, k, v: -1) |> std/io:print.ln("(integer) 1")
                            | empty |> std/io:print.ln("(integer) 0")
                        | else |> std/io:print.ln("(integer) 0")
                    | missing |> std/io:print.ln("(integer) 0")
                | else |> std/io:print.ln("ERR NOAUTH")
            | `INCR (?<k>[a-z_]+)` { k } |> if(session.stage == 1)
                | then |> std/string-map:get(m, k)
                    | value rv |> if(rv >= 0)
                        | then |> std/string:parse-int(s: kv[rv].val.data)
                            | ok n |> std/string:from-int(n: n + 1)
                                | ok sn |> std/string:take(s: sn): oval |> std/store:stored { kv[rv].val: oval } |> std/io:print.ln("(integer) {{ n + 1:d }}")
                                | err _ |> _
                            | err _ |> std/io:print.ln("ERR value is not an integer")
                        | else |> put(m, k, v: "1", reply: "(integer) 1")
                    | missing |> put(m, k, v: "1", reply: "(integer) 1")
                | else |> std/io:print.ln("ERR NOAUTH")
            | `QUIT` _ |> std/store:stored { session.stage: 2 } |> std/io:print.ln("bye")
            | no-match |> std/io:print.ln("ERR unknown command")
    | done _ |> std/string-map:free(m)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
