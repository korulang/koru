// A ROW IS REACHABLE BY POSITION, through a grid of handles.
//
// The store's addressing rule is that a row is named by a HANDLE and never by a
// position, and that rule was read for months as "an ECS `Vec<Entity>` is not
// expressible" — the ECS benchmark's `fanout` port carried the sentence "that
// access is not spellable and no amount of cleverness makes it so" as
// justification for diverging from both its anchors.
//
// IT IS SPELLABLE. A `std/grid` IS positionally addressed, so a grid whose cells
// hold handles is exactly the missing index. Position -> handle -> row:
//
//     agents[xref[i].h].hp
//
// Nothing new was built to make this work. 690_249 taught a write's row address
// to carry a nested read; a grid read is just another read in that slot, and it
// composes at the second hop. The wall was a habit of spelling, not a limit.
//
// WHAT THIS PINS, three things that must hold together:
//   - the two-hop address lowers on the WRITE side (`agents[xref[..].h].hp:`),
//     where reads have composed since 690_245 but writes stopped at one hop;
//   - the same two-hop address lowers in the VALUE, so a hit ACCUMULATES onto
//     the row instead of overwriting it;
//   - a computed, COLLIDING index works — the map below is `aid % 3`, so row 0
//     is hit three times, row 1 three times, row 2 twice, and rows 3..7 never.
//     A permutation would have made every row identical and pinned nothing.
//
// This is the shape every scatter-into-a-neighbour workload needs, and it is
// what let `archetype_churn_world` agree with bevy_ecs bit-for-bit: its attack
// system damages `entities[(target + id*13) % count]`, which is this and only
// this.
import std/io
import std/store
import std/grid

std/store:new(agents, capacity: 8) { aid: i64, hp: i64 }
std/grid:new(xref, size: 8) { h: 0[i64] }

// Build the corpus and its position->handle index in one pass: the insert's
// `row` arm carries the handle, and the loop counter is the position.
for(0..8)
! each i |> std/store:insert(agents) { aid: @as(i64, @intCast(i)), hp: 100 }
    | row t |> std/grid:stored { xref[i].h: t }
    | full |> _

// Every row damages the row at `aid % 3`. The write's row address reads the
// grid at a computed index; the value reads the SAME address, one hop deeper
// than any previous test goes.
std/store:query(agents)
! query a |> std/store:stored { agents[xref[@as(usize, @intCast(@mod(a.aid, 3)))].h].hp: agents[xref[@as(usize, @intCast(@mod(a.aid, 3)))].h].hp - 35 }

std/store:query(agents)
! query e |> std/io:print.ln("aid {{ e.aid:d }} hp {{ e.hp:d }}")
