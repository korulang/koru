// PINS the grid's READ where it is not a write block's value: in a guard, in
// an interpolation, under a loop, and with a loop binding as the index.
//
// The declaration owns a whole-program read pass, the mirror of the one
// `std/store:new` runs for singleton cell paths. Before it, `stored`'s value
// was the ONLY position a `<grid>[<i>].<field>` lowered, so `if(cells[3].on ==
// 6)` compiled to a Zig undeclared identifier — which meant no grid program
// could branch on what a cell holds, which is most of what a table is for. The
// prime sieve's primality guard and day 06's clamped decrement are the two real
// programs that could not be written; this is the small one that says why.
//
// FOUR POSITIONS, and the third is the one that got away:
//   (1) a top-level guard;
//   (2) an interpolation inside a string — masked, so only text between `{{ }}`
//       is treated as an expression and prose is left alone;
//   (3) a guard UNDER A LOOP, which is a different code path and not obviously
//       so: `if`/`for` bake their Expression argument into
//       `Invocation.inline_body` at template-expansion time, BEFORE any
//       declaration's pass runs, so rewriting `inv.args` alone updates a copy
//       nobody emits. store.kz has carried a comment about this since 690_074
//       and it was still worth an hour to rediscover — (1) and (2) were green
//       while (3) was broken;
//   (4) a WRITE whose index and value are both the loop's binding, which is the
//       operand-threading half: a write unit with no inputs cannot see `i`, so
//       the index and value are evaluated at the site and passed in.
//
// The oracle is arithmetic that could not come out right by accident: cell 3
// holds 3*2=6 from the loop, and 6 is only reachable if the write saw the
// binding and the read saw the write.
import std/io
import std/store
import std/grid

std/grid:new(cells, size: 8) { on: 0[i64] }
std/store:new(acc) { n: 0[i64] }

for(0..4)
! each i |> std/grid:stored { cells[i].on: @as(i64, @intCast(i)) * 2 }
| done |> if(cells[3].on == 6)
    | then |> std/io:print.ln("under-loop guard sees the write")
    | else |> std/io:print.ln("BAD under-loop guard")

if(cells[2].on == 4)
| then |> std/io:print.ln("top-level guard ok")
| else |> std/io:print.ln("BAD top-level guard")

// cells[1] in the prose is NOT an expression; the interpolated one is.
std/io:print.ln("cells[1].on reads {{ cells[1].on:d }}")

std/grid:sweep(cells)
! sweep c when c.on > 0 |> std/store:stored { acc.n: acc.n + c.on }

std/io:print.ln("sum {{ acc.n:d }}")
