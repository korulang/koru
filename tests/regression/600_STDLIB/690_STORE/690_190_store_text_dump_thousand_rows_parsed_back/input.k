// PINS: the serialize workload hand-rolled at ecs_bench_suite scale — 1,000
// rows dumped to ONE text artifact and parsed back into a second store, the
// values crossing as TEXT, not as projections. Serialize: per row,
// std/string:from-int renders each i64, append builds the dump in an
// owned-string buffer row ("id hp id hp ..."). Deserialize: ONE flat split
// (a nested field split trips 690_191), each token re-parsed with
// from-page + parse-int, a staging singleton pairs alternating tokens into
// insert(dst) rows — the pending id crosses through an echo tor because an
// insert literal cannot read a cell path (690_192).
//
// The oracle: dump byte length (8890 = 2890 id digits + 4000 hp digits +
// 2000 separators — digit-exact), then row count, sum(id), sum(hp), and the
// pairing sum sum(id*hp) over the REBUILT store, so a value that failed to
// survive the text, a dropped row, or a repaired pairing all break it.
//
// There is no whole-store save/load verb (the gauntlet-2 hole); this program
// is the floor a verb must beat — 40 lines of hand-rolled envelope for two
// i64 columns, and no float column can cross at all (std/string has
// parse-int/from-int only; no float mirror).
import std/io
import std/string
import std/store
import std/fmt

tor echo { v: i64 } -> i64
echo -> v

std/store:new(src, capacity: 1000) { id: i64, hp: i64 }
std/store:new(dst, capacity: 1000) { id: i64, hp: i64 }
std/store:new(buf, capacity: 2) { text: *std/string:String<instance!> }
std/store:new(pstate) { have: 0[i64], pid: 0[i64] }
std/store:new(check) { rows: 0[i64], ids: 0[i64], hps: 0[i64], pair: 0[i64] }

for(0..1000)
! each i |> std/store:insert(src) { id: @as(i64, @intCast(i)), hp: 1000 + @as(i64, @intCast(i)) }

std/string:from-page(text: "")
| ok s |> std/string:take(s): m |> std/store:insert(buf) { text: m }
    | row _ |> _
| err _ |> _

std/store:query(src)
! query r |> std/store:query(buf)
    ! query b |> std/string:from-int(n: r.id)
        | ok t1 |> std/fmt:ln("{{ t1:S }}"): k1 |> std/string:append(s: b.text, k1.text)
            | ok |> std/string:append(s: b.text, text: " ")
                | ok |> std/string:from-int(n: r.hp)
                    | ok t2 |> std/fmt:ln("{{ t2:S }}"): k2 |> std/string:append(s: b.text, k2.text)
                        | ok |> std/string:append(s: b.text, text: " ")
                            | ok |> _
                            | err _ |> _
                        | err _ |> _
                    | err _ |> _
                | err _ |> _
            | err _ |> _
        | err _ |> _

std/store:query(buf)
! query b |> std/string:len(s: b.text): n |> std/io:print.ln("dump bytes {{ n:d }}")

std/store:query(buf)
! query b |> std/fmt:fmt.blk {
    {{ b.text:S }}
}: dump |> std/string:split(s: dump, sep: " ")
    ! piece tok |> std/string:from-page(text: tok)
        | ok h |> std/string:parse-int(s: h)
            | ok n |> if(pstate.have == 0)
                | then |> std/store:stored { pstate.pid: n, pstate.have: 1 }
                | else |> echo(v: pstate.pid): pv |> std/store:insert(dst) { id: pv, hp: n }
                    | row _ |> std/store:stored { pstate.have: 0 }
            | err _ |> _
        | err _ |> _
    | done _ |> _

std/store:query(dst)
! query d |> std/store:stored { check.rows: check.rows + 1, check.ids: check.ids + d.id, check.hps: check.hps + d.hp, check.pair: check.pair + d.id * d.hp }

if(check.rows > 0)
| then |> std/io:print.ln("rows {{ check.rows:d }} ids {{ check.ids:d }} hps {{ check.hps:d }} pair {{ check.pair:d }}")
| else |> _
