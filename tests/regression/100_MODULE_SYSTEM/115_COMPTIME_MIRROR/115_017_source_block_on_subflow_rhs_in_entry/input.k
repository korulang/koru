// A source block opened on the RHS of a subflow DEFINITION — `run = <event> {`.
// Nothing in the corpus writes this position: source blocks appear as a
// top-level statement head or after `|>`, never as the opening token of a
// subflow body. Entry file, so the module system is not involved.
//
// Two readings, and which one holds is unruled: either a subflow body is a
// flow like any other and may open with a source-block-carrying event, or the
// position is illegal and this file should be rejected on purpose. What is a
// defect under BOTH readings is the diagnostic — PARSE001 reports "Source block
// missing closing brace" for a block whose braces balance, so it names a fault
// that is not the fault, and it is the sentence that would send an author
// hunting for a brace.
//
// 115_015 relocates the same construct into a module; keeping this arm in the
// entry file is what says the position rather than the relocation is at issue.
import std/io

pub tor run {}
run = std/io:print.blk {
    First block.
}

run()
