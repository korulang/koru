// Two unguarded `!` handlers for the same effect are multicast (subscribe),
// not exclusive "else" ambiguity. Language allows it; emission fires both.
// (branch_checker already: effect links may repeat; KORU051 was wrongly
// treating them as too-many-elses. Contrast `|` outcomes, which stay exclusive.)
import std/io

pub event ticker { n: usize }
! tick usize

proc ticker|zig {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        tick(i);
    }
}

ticker(n: 2)
! tick i |> std/io:print.ln("a {{ i:d }}")
! tick i |> std/io:print.ln("b {{ i:d }}")
