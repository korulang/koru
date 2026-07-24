// Bare-return produce (`-> e`) in a `#L`/`@L` label-fold LOOP-EXIT arm.
//
// A `#L` loop's terminal arm satisfies the enclosing event's bare return by
// producing a value with `->` — exactly like a non-loop handler arm (020_025,
// `| big b -> b * 100`), just on the label-fold emission path instead of the
// subflow/switch path. `run` is declared `-> i64`; the loop sums 5+4+3+2+1 and
// the `| done e -> e` exit arm produces the total.
//
// Guards the loop-exit emission path specifically: the bare-return signal must
// reach emitFlow's loop-exit arm and produce `return e;`, never a discard. The
// sibling on the non-loop path is 020_025.
import std/io

tor step { n: i64, acc: i64 }
| more { n: i64, acc: i64 }
| done i64

tor run { start: i64 } -> i64

step = if(n > 0)
| then => more { n: n - 1, acc: acc + n }
| else => done acc

run = #L step(n: start, acc: 0)
| more s |> @L(s.n, s.acc)
| done e -> e

run(start: 5): r |> std/io:print.ln("{{ r:d }}")
