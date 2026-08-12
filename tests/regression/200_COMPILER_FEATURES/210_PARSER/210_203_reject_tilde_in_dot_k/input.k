// A leading `` in a pure-Koru `.k` file is refused at the parser boundary.
//
// `` is the host->Koru switch: it is mandatory in a host-embedded `.kz`
// file, where it marks the line as Koru rather than Zig. A `.k` file has no
// host to switch away from, so the character has nothing to mean, and the
// wall refuses it outright rather than silently accepting a second spelling
// (src/parser.zig:854-865).
//
// The same rule reaches the interpreter from the other side: interpreted
// source is always pure Koru, so `findHostTilde` refuses a leading `` on
// every executing route (koru_std/interpreter.kz:724). 430_047 pins that
// half. This test pins the compiler half, which stood enforced and untested
// — the diagnostic's text lived in exactly one place, src/parser.zig, with
// nothing red if a refactor dropped it.
//
// The refusal is positional, not lexical: a tilde inside a string literal is
// data and stays legal (430_054 pins that), and a tilde inside a comment is
// skipped before the check runs.

~import std/io

std/io:print.ln("unreachable — the import above is refused first")
