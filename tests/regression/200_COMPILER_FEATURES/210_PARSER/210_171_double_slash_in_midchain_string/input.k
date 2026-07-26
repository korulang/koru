// PINS: `//` inside a string literal is string content, in every position.
//
// At a flow HEAD the parser gets this right — `get(url: "https://…")` has
// worked since the curl lift shipped. One step down the chain it does not: the
// `//` is taken as a line comment, the rest of the line vanishes, and what
// reaches the author is
//
//     error[PARSE003]: unbalanced parentheses in invocation arguments
//
// pointing at the whole line, blaming parentheses that are perfectly balanced.
//
// Both positions are in this file deliberately, so a fix cannot pass by making
// the head behave like the chain. The literal is identical in both.
//
// Found writing a parallel-download example: every URL in a pipeline is this
// shape, so the first real program to chain an HTTP call hits it immediately.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor take { n: i64, s: string } -> i64
proc take|zig { _ = s; return n; }

take(n: 1, s: "https://example.com"): a |> std/io:print.ln("head {{ a:d }}")

seed(): n |> take(n, s: "https://example.com"): b |> std/io:print.ln("chain {{ b:d }}")
