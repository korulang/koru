// Oracle: the SAME computation as 390_091 but with init at top level (the
// working fusion path). Its output is ground truth for the nested version.
import std/kernel
import std/io

std/kernel:shape(Body) {
    v: f64,
    acc: f64,
}

std/kernel:init(Body) {
    { v: 1, acc: 0 },
    { v: 2, acc: 0 },
    { v: 3, acc: 0 },
}
| kernel k |> std/kernel:step(0..2)
    | step |> std/kernel:pairwise {
            const s = k.v + k.other.v;
            k.acc += s;
            k.other.acc += s;
        } |> std/kernel:self {
                k.v += k.acc;
            }
| computed c |> std/io:print.blk {
        v0={{ c[0].v:f }}
    }
