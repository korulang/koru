// PINS: a split nested under another split's piece arm — the deserializer's
// natural shape (split the dump into records, split each record into fields).
// Both invocations are the same proc tor; the inner body is inlined into the
// outer's piece arm, and the labels the emitter mints for the two proc bodies
// must be distinct in that nesting. 690_190's flat one-separator format is the
// detour every hand-rolled parser takes around this shape.
import std/io
import std/string

std/string:split(s: "a b;c d", sep: ";")
! piece line |> std/string:split(s: line, sep: " ")
    ! piece tok |> std/io:print.ln("tok {{ tok:s }}")
    | done _ |> _
| done _ |> _
