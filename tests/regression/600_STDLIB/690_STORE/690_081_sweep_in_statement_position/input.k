// PINS: `std/store:sweep` is legal in STATEMENT position, not only as a chain
// step.
//
// A sweep that begins a statement emits its loop at FILE SCOPE — a bare `{ … }`
// block where Zig expects a declaration — and the host says
// `expected type expression, found '{'`. Put anything in front of it so it
// becomes a chain step and the identical sweep compiles and runs:
//
//     std/store:query(nums)                          <- refused (this test)
//     std/io:print.ln("start") |> std/store:query(nums)   <- compiles, prints
//
// The discriminator is POSITION and nothing else: same store, same arm, same
// projection. It is not about subflows (a `scan = std/store:query(nums)` head
// fails identically), not about obligations, and not about what the arm calls.
// Every sweep in the corpus and in koru-examples/gallery happens to be chained,
// which is why a statement-position sweep had never been emitted.
//
// A host error reaching the author is its own defect: there is no koru-level
// wall here, so the failure arrives as Zig syntax about generated code the
// author never wrote.
import std/io
import std/store

std/store:new(nums, capacity: 4) { n: i64 }

std/store:insert(nums) { n: 1 }
| row _ |> _

std/store:query(nums)
! query e |> std/io:print.ln("n={{ e.n:d }}")
