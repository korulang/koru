// A bare return can be a SLICE type: `-> []const u8`. The output type axis is
// {scalar (020_021), slice (here), record (020_024)} — `->` means "the single
// output is exactly this type", with no restriction on which type. Flat-produce
// form (`~echo -> s`), the same as the scalar 020_021.
import std/io

pub event echo { s: string } -> string
echo -> s

echo(s: "hello"): r |> std/io:print.ln("{{ r:s }}")
