import std/io

pub event checkgap { s: []const u8 }

checkgap = capture { found_gap: 0[i64], p2: -1[i64], p1: -1[i64] }
! as st |> for(s)
    ! each c |> captured { found_gap: @max(st.found_gap, @intFromBool(st.p2 == @as(i64, c))), p2: st.p1, p1: @as(i64, c) }
| captured r |> std/io:print.ln("gap={{ r.found_gap:d }} p1={{ r.p1:d }} p2={{ r.p2:d }}")

checkgap(s: "uurcxstgmygtbstg")
checkgap(s: "ieodomkazucvgmuy")
