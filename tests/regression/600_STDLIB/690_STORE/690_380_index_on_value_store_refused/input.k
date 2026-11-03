// PINS: the REFUSAL of an `std/indexes` declaration on a capacity-1 VALUE
// store. The index machinery lives on the plural container's emit path —
// on a value store the declaration can never produce machinery and its only
// readers (query/first) refuse on the tier anyway (690_354). A dead claim
// the author believes is live — refused at the declaration's own location.
import std/store
import std/indexes
import std/io

std/store:new(game) { entities: 0[i64] }
std/indexes:store(game, entities)

std/io:print.ln("unreachable")
