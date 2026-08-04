// PINS: a `for` LOOP is a legal next link of a grid write's chain, in all three
// positions a five-baton-old claim said it was not.
//
// THE CLAIM, carried in koru-libs/raylib/tests/boids.k:27-29 and in five
// consecutive session batons: "a store write followed by |> for(..) does not
// compose, and nested in an arm it silently accumulates nothing." Both halves
// are false on this tree, and the pin is here so nobody carries it a sixth time.
//
// 697_012 pinned the chain tail when the next link is a `print` or a second
// WRITE. A `for` was never the next link anywhere in the corpus, so the fix
// that stopped grid writes discarding their tail was never measured against a
// loop — the commonest thing anyone would actually pipe a write into.
//
// THREE POSITIONS, and the third is the one the claim called silent:
//   HEAD      — write at the flow head, `for` as its next link.
//   SAME COLUMN — the loop accumulates into the very column the preceding write
//                 seeded, so it must observe that write, not the pre-state.
//   IN AN ARM — write and `for` both inside a `! each` arm. Named "silently
//               accumulates nothing"; it accumulates exactly.
//
// LAYOUT, and it is the one live constraint here: the `|> for(..)` link must sit
// on the SAME LINE as the write. Written as an indented continuation line it is
// refused with KORU010 whether the loop's arms are at column 0 or indented under
// it, because the arms have no construct to attach to. boids.k writes every
// chain link on its own continuation line, which is how a layout refusal was
// read as "does not compose" and became a semantic claim about the store.
import std/io
import std/grid

std/grid:new(g, size: 4) { n: 0[i64], sum: 0[i64] }

// HEAD: the write lands and the loop after it runs.
std/grid:stored { g[0].n: g[0].n + 1 } |> for(0..3)
! each _ |> std/grid:stored { g[1].sum: g[1].sum + 1 }
| done |> _

// SAME COLUMN: 10 seeded by the write, then three increments observing it.
std/grid:stored { g[2].sum: 10 } |> for(0..3)
! each _ |> std/grid:stored { g[2].sum: g[2].sum + 1 }
| done |> _

// IN AN ARM: two outer iterations, each writing then running its own loop.
for(0..2)
! each _ |> std/grid:stored { g[3].n: g[3].n + 1 } |> for(0..3)
    ! each _ |> std/grid:stored { g[3].sum: g[3].sum + 1 }
    | done |> _
| done |> _

std/io:print.ln("head {{ g[0].n:d }},{{ g[1].sum:d }} same {{ g[2].sum:d }} arm {{ g[3].n:d }},{{ g[3].sum:d }}")
