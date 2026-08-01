// A `watch ! row` rule is a RULE — it joins the stripe like any other.
//
// The companion to 690_236, and the pin that catches the tempting wrong
// implementation. 690_236 says a watch does not read at the point you wrote
// it, and the obvious way to get that is to stop emitting the rule's
// whole-pass form (its qsweep) altogether. That passes 690_236 and quietly
// costs the rule the ability to be SCHEDULED, because `stripe` drives whole
// passes by chaining exactly those units — a rule with no qsweep cannot be
// striped at all. Caught here rather than in review.
//
// So the axis is not "does this site have a whole-pass form" (every row-scoped
// site does) but "who CALLS it". `query` calls it at its own position;
// `watch ! row` leaves it for the stripe.
//
// Both rows are inserted BEFORE the watch, so a root-position sweep would
// print them immediately. Nothing may appear until `-- stripe --`; then the
// stripe runs the rule over the whole corpus.
import std/io
import std/store

std/store:new(game, capacity: 8) { hp: 0[i64] }

std/store:insert(game) { hp: 1 }
| row _ |> _
| full |> _

std/store:insert(game) { hp: 2 }
| row _ |> _
| full |> _

[name(alpha)]std/store:watch(game)
! row a |> std/io:print.ln("A {{ a.hp:d }}")

std/io:print.ln("-- stripe --")
std/store:stripe(game)
