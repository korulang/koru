// PINS: the point-free thread fills its punned slot even when the stage takes
// OTHER arguments, and even when the thread came from a bare-return bind.
//
// Two extensions to the shipped point-free pipeline (210_151/152/153, and the
// `a-pyramid-is-a-pipeline-hand-unrolled` post). That feature threads a BRANCH
// into the next stage's identically-named input, and a stage may go BARE only
// when the thread is its whole input — "need more, and it keeps its
// parentheses."
//
// Lars 2026-07-27 wants the parentheses to keep only what the thread cannot
// provide:
//
//     [with]koru/curl:multi.new(): m
//         |> multi.add(url: "https://…")
//         |> multi.add(url: "https://…")
//         |> multi.start()
//
// `multi.add` takes `m` and `url`. The thread supplies `m` — the names line up,
// which is the same punning the shipped feature already leans on to "name the
// hole" — and `url` is written because nothing else can supply it.
// `multi.start()` takes only `m`, so its parentheses are empty.
//
// So: (1) PARTIAL fill, where today the rule is whole-input-or-explicit, and
// (2) a thread originating at a bare-return bind (`: m`) rather than a named
// branch.
//
// This fixture is (2) in isolation — `seed` bare-returns, `bump` takes only
// `n`. Today the call parses, nothing fills, the intermediate results are
// discarded, and the seed prints unchanged. Sibling of 210_172, which is the
// same silent discard seen from the other side: that pin asks a step's RESULT
// to move forward, this one asks the next stage's PARAMETER to be filled from
// it. A builder pipeline needs both, because its stages take and return the
// same name.
//
// `[with]` is NOT pinned here — it already works, including through branch
// arms. Neither is 210_174, though the multi-line form of Lars's example needs
// it too.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { n: i64 } -> i64
proc bump|zig { return n + 10; }

seed(): n |> bump() |> bump() |> std/io:print.ln("filled = {{ n:d }}")
