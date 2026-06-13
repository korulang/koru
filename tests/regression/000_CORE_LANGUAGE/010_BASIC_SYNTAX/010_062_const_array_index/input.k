// A const {} ARRAY literal + indexing, pure .k. The Zig target lowers the
// literal to a real Zig array (`[_][]const u8{ ... }`) with the element type
// INFERRED from the literals; JS keeps `[...]`. No annotation needed — the
// dual-target mirror of the scalar `42[i32]` (Zig pins, JS erases). Pins the
// const-array lowering in src/template_processor.zig (renderZigConstValue).
// Before it landed, `["a", ...]` pasted verbatim and broke the Zig backend.
import std/io

const {
    INPUTS: ["alpha", "beta", "gamma"]
}

std/io:print.ln("{{ INPUTS[0]:s }}")
std/io:print.ln("{{ INPUTS[1]:s }}")
std/io:print.ln("{{ INPUTS[2]:s }}")
