// PINS: a row handle still addresses its own row after a slot has been
// recycled past the JavaScript encoding's exact-integer range.
//
// A handle packs three fields into one i64: the sparse slot in the low 24
// bits, the minting store's brand above it, and that slot's generation in the
// high 32. On the Zig lane those are bit operations on sized integers, exact
// at every value. On the JS lane there are no 64-bit bitwise operators, so the
// same layout is assembled by ARITHMETIC — and `generation * 4294967296` is
// exact only while the product stays inside a double's exact-integer range.
// 2^21 * 2^32 IS 2^53. One generation past that, the slot in the low bits is
// rounded away and the handle stops being a bijection.
//
// WHAT THAT ACTUALLY BREAKS is quieter than a wrong row, which is why this
// test counts instead of comparing. A handle that no longer decodes fails the
// brand check, so `take` answers its `| empty` branch — the row is simply
// never removed. Nothing traps and nothing prints; the store just keeps a row
// the program believes it took, and every later handle into that slot is
// equally lost. A leak that presents as a successful removal.
//
// So the pin is the live count. The loop mints and kills a row in the same
// recycled slot far past the boundary; every one of those rows must actually
// leave. Afterwards exactly ONE row is alive — the one deliberately parked in
// slot 0 before the loop started. Two means a handle stopped resolving.
//
// The odd slot is the point. A brand contributes a multiple of 2^24 and stays
// even, so precision loss cannot reveal itself there; the low bit of the SLOT
// is the first thing to go, which is why the parked row takes slot 0 and the
// recycled one is slot 1.
import std/io
import std/store

std/store:new(tally) { live: 0[i64] }
std/store:new(log) { a: -1[i64], c: -1[i64] }

std/store:new(rows, capacity: 4) { v: i64 }
! inserted _ |> std/store:stored { tally.live: tally.live + 1 }
! removed _ |> std/store:stored { tally.live: tally.live - 1 }

std/store:insert(rows) { v: 100 }
    | row ra |> std/store:stored { log.a: ra }
    | full |> _

for(0..2097153)
! each _ |> std/store:insert(rows) { v: 200 }
    | row t |> std/store:take(rows[t])
        | item _ |> _
    | full |> _

std/io:print.ln("live after recycling one slot past the boundary: {{ tally.live:d }}")

std/store:insert(rows) { v: 300 }
    | row rc |> std/store:stored { log.c: rc }
    | full |> _

std/io:print.ln("a -> {{ rows[log.a].v:d }}")
std/io:print.ln("c -> {{ rows[log.c].v:d }}")
