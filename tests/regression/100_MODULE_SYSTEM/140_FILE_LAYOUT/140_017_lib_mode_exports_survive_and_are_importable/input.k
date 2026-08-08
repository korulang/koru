// PINS: `koruc lib` — compiling a LIBRARY rather than a program.
//
// The difference is not the output format. It is what counts as a ROOT.
// Compiling a program, the roots are its flows and anything nobody calls does
// not exist in the output — which is correct, because Koru has full visibility
// and there is no caller outside. Compiling a library, that premise inverts:
// the roots are what the entry module EXPORTS, and "nobody here calls it" is
// the normal case rather than evidence the thing is dead.
//
// NO NEW SPELLING. `pub` already means "visible outside this module", which is
// exactly the export list; a library is a compilation in which "outside"
// exists. What `koruc lib` changes is the root rule, not the surface.
//
// This test runs as a PROGRAM (it has a flow, so it is self-checking here) and
// pins the shared half: a `pub` entry point keeps its body. The library half —
// that the same file under `koruc lib --lang=js` emits named ESM exports a
// hand-written JS program can import — is exercised by the JS lane, where an
// importer calls `greet` and `add` and gets "hello Lars" and 42.
//
// The two exports differ ON PURPOSE: `greet` is flow-bodied and `add` is a
// bare-return tor. Those take different paths to emission, and only one of
// them survived stripping before this rung — so a pin that used just one would
// have passed against a half-working rule.
import std/io

pub tor greet { name: string }
greet = std/io:print.ln("hello {{ name:s }}")

pub tor add { a: i64, b: i64 } -> i64
add -> a + b

greet(name: "Lars")
add(a: 20, b: 22): sum |> std/io:print.ln("add is {{ sum:d }}")
