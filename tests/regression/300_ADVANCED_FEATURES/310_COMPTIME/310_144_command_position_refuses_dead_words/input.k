// Pins that a word in command position nothing declared is REFUSED — Q3 in
// challenges/018_FIX_QUEUE.md.
//
// `koruc <file> run` used to build and exit 0 — the leading verb typed in the
// trailing position was swallowed, and nothing else reads trailing words (they
// are never forwarded to the program). Now a leading verb there refuses and
// quotes the line the user meant, and any other undeclared word refuses as
// "not a command this file declares".
//
// Declared commands are untouched: `deps` still dispatches, `--check` in the
// same slot is a flag not a command, and `koruc run <file>` still runs.
import std/io

std/io:print.ln("ran-for-real")
