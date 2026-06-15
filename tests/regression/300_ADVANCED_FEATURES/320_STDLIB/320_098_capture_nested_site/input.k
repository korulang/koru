// RED PIN — capture nested under a continuation crashes the transform pass.
// `capture` emits flow-level preamble_code, which has no position inside a
// continuation site (here under `| count _`), so the pass aborts with
// TransformPreambleAtNestedSite. The error itself prescribes the fix: emit
// inline_body (statement-shaped) at nested sites. Blocks the canonical
// "build a collection, THEN fold it with an accumulator" shape (e.g. AoC day17).
// Minimal — no list / read-lines, just capture under a scalar branch.
import std/io
import std/args

std/args:count()
| count _ |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 }
    | captured r |> std/io:print.ln("n={{ r.n:d }}")
