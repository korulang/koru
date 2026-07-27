// A `|>` chain continuing after a MULTI-LINE source block that opened on a
// subflow-definition line. 210_168 pins the block itself; this pins the tail
// after its closing brace.
//
// Entry file, no module involved. The top-level form of exactly this chain is
// pinned by 320_093, so what this isolates is the subflow-definition path: the
// closing line carries `} |> <next>`, and the tail after it must reach the
// emitted output. A tail lost here is lost in silence — no diagnostic, no
// crash, just one block printed instead of two — which is what makes the shape
// worth a pin rather than a note.
//
// Sibling: 210_176, the same claim for a plain `print.ln` chain with no source
// block anywhere in it.
import std/io

pub tor run {}
run = std/io:print.blk {
    First block.
} |> std/io:print.blk { Second block on one line. }

run()
