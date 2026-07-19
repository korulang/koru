// Bare return of a RECORD type: `-> { a: T, b: U, ... }`.
//
// `->` produces the event's single output. That output may be a scalar (`-> i64`,
// 020_021), a slice (`-> []const u8`), OR a multi-field record `-> { total, doubled }`
// — the record form mirrors the event INPUT payload grammar (`{ field: T }`), so
// input and output share one shape. The call site binds it with `: r` and reads
// fields (`r.total`).
//
// A record earns its braces at TWO OR MORE fields. A single-field `-> { a }` is
// rejected (210_149): it is a distinction without a difference from the scalar
// `-> a` — same information, two spellings — so it collapses, exactly as a
// single-field branch payload collapses to identity (210_063) and a one-variant
// tag union collapses to a bare return (210_131).
import std/io

pub event run { x: i64 } -> { total: i64, doubled: i64 }
run -> { total: x * 2, doubled: x + x }

run(x: 21): r |> std/io:print.ln("{{ r.total:d }}")
