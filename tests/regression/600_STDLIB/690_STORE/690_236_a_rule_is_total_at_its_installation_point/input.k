// A RULE IS TOTAL AT ITS POINT OF INSTALLATION — the claim the whole store
// surface now rests on, made falsifiable.
//
// A rule is a standing statement about ROWS, not about writes. "Every foe at
// hp <= 0 is culled" is not a claim about future foes, so a rule that only
// reacted forward would be a lie about the corpus. Totality is assembled from
// two halves that no other verb combines:
//
//   rows written BEFORE the rule  -> the root-position sweep (the backfill)
//   rows written AFTER  the rule  -> the standing subscription
//
// This is exactly what `watch` does NOT do, and the distinction the old
// surface had no word for. `watch ! hp h` fires per WRITE; there are no past
// writes to replay, so backfill is meaningless for it. Rows are things that
// exist; writes are things that happen.
//
// n=1 and n=2 are inserted before, n=3 and n=4 after. All four must fire.
// Backfill dropped -> only 3 and 4. Subscription dropped -> only 1 and 2.
// Either half missing is visible here, which is why both sides are present.
import std/io
import std/store

std/store:new(seen, capacity: 8) { n: 0[i64] }

std/store:insert(seen) { n: 1 }
| row _ |> _
| full |> _

std/store:insert(seen) { n: 2 }
| row _ |> _
| full |> _

std/store:rule(seen)
! row e |> std/io:print.ln("rule saw {{ e.n:d }}")

std/store:insert(seen) { n: 3 }
| row _ |> _
| full |> _

std/store:insert(seen) { n: 4 }
| row _ |> _
| full |> _
