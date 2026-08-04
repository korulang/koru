// PINS: a `std/grid:stored` is ONE LINK of its chain, not the end of it.
//
// Two shapes, both of which were broken and in opposite ways.
//
// TAIL — a step piped after a write must run. The write's transform replaces
// the whole flow, and it used to build the replacement with an EMPTY
// continuation list, so everything after the write was discarded: the write
// landed, the next step vanished, exit 0, no diagnostic. Every `rootSite` call
// in store.kz passes the real continuations; the two in grid.kz passed nothing.
//
// SIBLING — two writes chained in one arm must both land. The write unit is a
// per-site event, and it was keyed on the FLOW's line, which every link of a
// chain shares. Inside a loop arm that minted one name twice and the Zig
// backend rejected the program with `duplicate struct member name` — an
// internal leak with no Koru-level diagnostic. The key now includes a hash of
// the block text, which is what actually distinguishes two links.
//
// THE ORDER OF THOSE TWO FIXES IS THE INTERESTING PART, and it is recorded in
// grid.kz at both sites. The name collision was fixed FIRST, alone, and it made
// the system worse: with the tail still being dropped, a unique key let the loop
// shape compile and silently print the wrong answer. The collision had been the
// only thing making the drop loud anywhere. A symptom can be load-bearing while
// the disease is untreated, and removing it first is how a loud bug becomes a
// quiet one.
//
// Neither shape had a test because every grid test in the corpus writes in
// STATEMENTS — 697_001 set that idiom the day the grid landed and nothing since
// deviated, so the whole surface was stepped around rather than exercised.
//
// Found by writing a boids renderer against libs/raylib: the frame arm was
// `std/grid:stored {..} |> draw.rect(..)`, the draw was the swallowed step, and
// the window came up black with nothing reporting anything.
import std/io
import std/grid

std/grid:new(g, size: 4) { x: 0[i64], y: 0[i64] }

// TAIL: the step after the write runs.
std/grid:stored { g[1].x: 1 }
    |> std/io:print.ln("the chain continues")

// SIBLING: two writes chained inside a loop arm, both land, and the loop
// binding is visible to both.
for(0..2)
! each k |> std/grid:stored { g[k].y: 5 }
    |> std/grid:stored { g[k].x: g[k].x + 2 }

std/io:print.ln("g0 {{ g[0].x:d }},{{ g[0].y:d }} g1 {{ g[1].x:d }},{{ g[1].y:d }}")
