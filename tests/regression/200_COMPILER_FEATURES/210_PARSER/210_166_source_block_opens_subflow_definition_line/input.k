// A source block may OPEN on a subflow-definition line and close on a later
// one — `run = std/io:print.blk {` … `}`. Ruled legal (Lars, 2026-07-26): a
// subflow body is a flow like any other, so an event carrying a source block
// heads one the same way it heads a top-level statement.
//
// The definition line is brace-unbalanced on its own, so the subflow path has to
// stitch following lines on until the braces close. Before it did, only `|>`
// continuation lines were stitched and the block read as unterminated — PARSE001
// "Source block missing closing brace" against balanced source, which is the
// diagnostic pointing at the wrong thing that made the gap look like a typo.
//
// Second block pins that the stitch is NEWLINE-joined: a block's content is
// emitted text, so its line structure is part of the value. Space-joining would
// collapse these two lines into one.
import std/io

pub tor run {}
run = std/io:print.blk {
    first line
    second line
}

run()
