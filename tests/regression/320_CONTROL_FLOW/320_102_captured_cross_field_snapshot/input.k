// Test 320_102: captured { } cross-field SNAPSHOT semantics.
//
// RULED (Lars, 2026-07-02): in a `captured { }` update, ALL field expressions
// are evaluated against the INCOMING accumulator state (`st` names the state
// at round entry), and only then does the accumulator update — simultaneous
// assignment, fold semantics. The meaning of the literal must NOT depend on
// the textual order of its fields.
//
// TODAY (the bug this pins): the emitter lowers the literal to sequential
// in-place assignments on the same struct, in declaration order — so
// `found_gap`'s expression below reads the just-overwritten `st.p2` (one-back
// char) instead of the incoming `st.p2` (two-back char), silently computing
// the wrong predicate. Reordering the fields in source flips the answer.
//
// The field order here is DELIBERATELY the order that today's sequential
// lowering gets wrong: `p2` is reassigned before `found_gap` reads `st.p2`.
// Expected output is the snapshot-semantics answer (AoC day 5 part 2 gap
// predicate: uurcxstgmygtbstg has NO gap letter, ieodomkazucvgmuy has one).
import std/io

pub event checkgap { s: string }

checkgap = capture { p2: -1[i64], p1: -1[i64], found_gap: 0[i64] }
! as st |> for(s)
    ! each c |> captured { p2: st.p1, p1: @as(i64, c), found_gap: @max(st.found_gap, @intFromBool(st.p2 == @as(i64, c))) }
| captured r |> std/io:print.ln("gap={{ r.found_gap:d }} p1={{ r.p1:d }} p2={{ r.p2:d }}")

checkgap(s: "uurcxstgmygtbstg")
checkgap(s: "ieodomkazucvgmuy")
