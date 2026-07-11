// PIN (2026-07-05, honest red): std/io:read.ln() leaks its line buffer.
// The implementation dupes the line via koru_allocator() and returns it as
// a bare []const u8 — no phantom obligation, no companion free event — so
// the leak checker fires on ANY program that calls it:
//     KORU LEAK CHECK FAILED: the produced program leaked
// The program itself works (prints the line first). Either read.ln grows
// an obligation + free story like the rest of the stdlib, or it borrows
// like read-lines' streaming arm. Surfaced by the wordfreq kernel port
// (which used read-lines instead — the grounded, leak-free path).
//
// Correct behavior: prints the line and exits leak-clean.
import std/io

std/io:read.ln()
| ok l |> std/io:print.ln("got: {{ l:s }}")
