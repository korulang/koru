// Pins the UNRESOLVED-ONLY guarantee of `[with]` scoped vocabulary: a bare name
// that already resolves LOCALLY is never shadowed by an opened region, even when
// the opened module also owns that name. Here `warn` exists both in the main
// module (below) and in std/io. The `[with]std/io` region must resolve bare
// `warn` to the LOCAL event — the resolver only restamps names the main module
// does NOT own (the `!has(main, seg)` guard). If the guard ever regressed to
// shadow-on-open, bare `warn` would route to std/io's `⚠️`-printing proc and
// this test's `local-warn:` line would vanish.
import std/io

pub event warn { msg: []const u8 } -> []const u8
warn -> msg

[with]std/io:print.ln("open") |> warn(msg: "kept"): w |> std/io:print.ln("local-warn: {{ w:s }}")
