// Pins the TYPED VALUE CHANNEL gap: a grammar cannot hand a parsed piece back
// as anything but text. The value slot every rule produces is nailed to a text
// span (koru_std/parser.kz `val: []const u8` + `sub ... -> string`), so a
// number parsed by the grammar arrives as the characters "42", never the
// integer 42. This test demands the number as an integer (`{{ v:d }}`); it
// stays red until the parse's capture/return channel can carry a rule's
// declared typed value instead of a span. This is the capability everything
// downstream (building a JSON value, building Koru's own AST) waits on.
import std/parser
import std/io

[with]std/parser:grammar(nums)
! value v |> match(v)
    | `-?[0-9]+` n -> n

std/parser:parse("42", grammar: nums)
| value v |> std/io:print.ln("as-int={{ v:d }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")
