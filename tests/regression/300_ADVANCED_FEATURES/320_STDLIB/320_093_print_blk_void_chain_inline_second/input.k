// Second print.blk in a void chain can be entirely on one line after `|>`.
// Exercises inline `} |> event { content }` — block closes on the same line.

import std/io

std/io:print.blk {
    First block.
} |> std/io:print.blk { Second block on one line. }
