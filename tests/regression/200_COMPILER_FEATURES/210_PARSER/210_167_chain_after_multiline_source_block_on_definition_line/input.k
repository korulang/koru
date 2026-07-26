// A `|>` chain continuing after a MULTI-LINE source block that opened on a
// subflow-definition line. 210_166 pins the block itself; this pins the tail
// after its closing brace.
//
// Entry file, no module involved. The top-level form of exactly this chain works
// (320_093), so what this isolates is the subflow-definition path: the closing
// line carries `} |> <next>`, and the second step reaches neither the emitted
// output nor a diagnostic — it is dropped in silence, which is the part that
// makes it worth a pin rather than a note.
import std/io

pub tor run {}
run = std/io:print.blk {
    First block.
} |> std/io:print.blk { Second block on one line. }

run()
