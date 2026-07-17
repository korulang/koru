// `if` arms PRODUCE a bare-return event's `-> T` value with `->`:
//   ~pick = if(n < 10) | then -> n | else -> n - 10
// Each arm's `->` satisfies the enclosing event's single return — the same
// produce glyph a continuation handler uses (020_025), now through `if`.
// This is part 1 of the single-return-form endeavor: a single output is the
// scalar `-> T` form, never a one-branch tag union (210_131 pins the reject).
// The handler must lower to a plain scalar `Output = T` with `return` in both
// arms — no union, no tag, no data movement beyond the value itself.
import std/io

event pick { n: i64 } -> i64
pick = if(n < 10)
| then -> n
| else -> n - 10

pick(n: 21): a |> std/io:print.ln("{{ a:d }}")
pick(n: 3): b |> std/io:print.ln("{{ b:d }}")
