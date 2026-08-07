// One source, two targets. A container store of 4096 entities, 50 000 frames
// of `pos += vel` written as a two-column `stored` block in a sweep arm, then
// one aggregate sweep folding every `px` into a singleton store.
//
// Nothing here is written for a target: no conditional compilation, no host
// block, no shim. `koruc ecs_integration.k` and `koruc ecs_integration.k
// --lang=js` compile the same file, and the checksum is the proof they agree.
//
// Every shape is pinned green on both targets by a regression test:
//   690_011  the container store and its insert branches
//   690_067  a `for` driving a store sweep
//   690_118  a `stored` block writing two columns of the swept row
//   690_041  a singleton store used as an accumulator
//
// The `@as(i64, @intCast(i))` is load-bearing and NOT ceremony: `for` yields a
// `usize` and `px` is `i64`, which Zig refuses (010_064 pins the gap). JS has
// one number type and accepts the loop variable bare — so this program compiled
// to JavaScript BEFORE it compiled to Zig, and the cast is what makes one
// source serve both. `@intCast` is in the shared vocabulary table, so it lowers
// to the value on JS rather than being passed through.
import std/io
import std/store

std/store:new(total) { sum: 0[i64] }
std/store:new(ents, capacity: 4096) { px: i64, vx: i64, py: i64, vy: i64 }

for(0..4096)
! each i
    |> std/store:insert(ents) { px: @as(i64, @intCast(i)), vx: 1, py: @as(i64, @intCast(i)), vy: 2 }
        | row _ |> _
        | full |> _

for(0..50000)
! each f
    |> std/store:query(ents)
        ! query e
            |> std/store:stored { e.px: e.px + e.vx, e.py: e.py + e.vy }

std/store:query(ents)
! query r
    |> std/store:stored { total.sum: total.sum + r.px }

std/io:print.ln("checksum {{ total.sum:d }}")
