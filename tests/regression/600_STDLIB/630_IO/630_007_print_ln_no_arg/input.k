// PIN: `print.ln()` with no argument emits the terminator alone —
// expr is `?Expression`, and an absent argument lowers to printing
// an empty string plus the newline (the print/print.ln decls share
// this; print() with no arg emits nothing at all).

import std/io

std/io:print("a")
std/io:print.ln()
std/io:print.ln("b")
std/io:print.ln("")
std/io:print("c")
std/io:print.ln()
