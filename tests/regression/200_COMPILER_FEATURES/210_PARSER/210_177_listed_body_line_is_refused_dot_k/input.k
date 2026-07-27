// PINS: a line indented under a subflow definition belongs to that subflow's
// body or it is refused — it is never silently rehomed.
//
// Koru sequences a body with `|>`. Listing is not a body form, so nothing in
// the grammar claims lines two and three here. Where they went instead is why
// this is a pin and not a style note: they were promoted to TOP-LEVEL flows
// and ran at program start. `greet` is never called anywhere in this file, and
// the program still printed `two` and `three` — the author's lines ran, in the
// wrong place, at the wrong time, with no diagnostic.
//
// The control is the same three steps, chained:
//
//     greet = std/io:print.ln("one")
//         |> std/io:print.ln("two")
//         |> std/io:print.ln("three")
//
// One glyph apart, and the whole difference between three lines that run when
// `greet` is called and two that run whether it is called or not.
//
// The refusal must name the author's line. A stray body line is not a wrong
// program the compiler can guess the intent of — `|>` and a dedent mean
// different things, and only the author knows which was meant — so the
// diagnostic points at the line and offers both spellings.
//
// `.kz` twin: 210_178. There the same shape leaks the line to the HOST and
// surfaces as a Zig parse error against generated code. The axis that splits
// the two symptoms is the file form, not whether the calls cross a module
// boundary — both forms misbehave with local calls and with `std/io` alike.
import std/io

tor greet {}

greet = std/io:print.ln("one")
        std/io:print.ln("two")
        std/io:print.ln("three")

std/io:print.ln("-- greet is never called --")
