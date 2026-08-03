// A STANDING RULE CAN NAME THE HANDLE OF THE ROW IT IS VISITING, and the
// handle it hands out is RETAINABLE — it still addresses that row after a
// swap-remove has moved the row somewhere else.
//
// `[id]` landed on sweep arms first (690_246). On a `rule` arm any destructure
// was refused as "the retired projection block" — a wrong error on a legal
// construct, since a request block is not a projection block. RULED 2026-08-03:
// `[id]` is admissible here, and the gate is why. Clause 1 says the request
// names something the SITE knows and the ROW does not, and SITE is deliberate:
// a rule has a ROW and no TRAVERSAL, so a handle is exactly as meaningful here
// as on a sweep (a handle does not depend on traversal) while `[ordinal]` is
// meaningless and refused BY NAME (690_248). A gate phrased around "the VISIT"
// would have collapsed *meaningless here* into *unimplemented here*.
//
// WHAT THIS PROVES, and it is the retention clause end to end:
//
//   units: a(hp 10) -> dense 0, b(hp 20) -> dense 1, c(hp 0) -> dense 2
//   the rule enters on c's insert, `[id]h` names c's HANDLE, the body writes it
//     into a sibling store — the external index the store never maintains for you
//   take(units[b]) swap-removes b, RELOCATING c from dense 2 to dense 1
//   `units[mark.who].hp: 777` follows the STORED handle
//
// The 777 lands on c at its NEW position. A position would have addressed dense
// 2 — past `len`, inside capacity, writing nothing anyone reads, which is
// exactly the silent corruption 690_092 measured before O10.iii shipped. So the
// value `[id]` mints on a rule arm is the same handle `| row` mints, carrying
// brand and generation, and clause 2 of the gate ("a value that may OUTLIVE the
// visit must be generation-checked") is satisfied rather than assumed.
//
// The motivating workload is the one that earned `[id]` in the first place: a
// reactive chain update needs the visited row to name itself as a value.
import std/io
import std/store

std/store:new(units, capacity: 64) { hp: i64 }
std/store:new(mark, capacity: 1) { who: 0[i64] }

std/store:rule(units)
! row { [row]e, [id]h } when e.hp <= 0 |> std/store:stored { mark.who: h }

std/store:insert(units) { hp: 10 }
| row a |> std/store:insert(units) { hp: 20 }
    | row b |> std/store:insert(units) { hp: 0 }
        | row c |> std/store:take(units[b])
            | item gone |> std/io:print.ln("took {{ gone.hp:d }}")
                |> std/store:stored { units[mark.who].hp: 777 }

std/store:query(units)
! query u |> std/io:print.ln("unit hp {{ u.hp:d }}")
