// RED PIN — capture nested under a continuation crashes the transform pass.
// `capture` was built for FLOW LEVEL only; nesting it under a continuation
// (here `| count _`) is a MULTI-LAYER gap, not a one-line fix (probed 2026-06-15):
//   layer 1: itemToNode rejects flow-level preamble_code at a nested site
//            (TransformPreambleAtNestedSite). Migrating preamble→front-of-
//            inline_body clears it — but then:
//   layer 2: the shape checker rejects the spliced capture continuations as a
//            duplicate branch handler (SHAPE002), and likely more below (emission).
// So this needs a real rework of capture (or the nested-site splice) across
// transform_pass_runner + shape_checker + emission — a dedicated investigation,
// not a patch. Blocks the canonical "build a collection, THEN fold it with an
// accumulator" shape (e.g. AoC day17's subset count).
// Minimal — no list / read-lines, just capture under a scalar branch.
import std/io
import std/args

std/args:count()
| count _ |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
