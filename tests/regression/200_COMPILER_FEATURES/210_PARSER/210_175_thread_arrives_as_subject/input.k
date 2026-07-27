// PINS: the point-free thread arrives in a parameter named `subject`.
//
// Ruled by Lars 2026-07-27. The shipped point-free pipeline
// (210_151/152/153, and the `a-pyramid-is-a-pipeline-hand-unrolled` post)
// threads a BRANCH into the next stage's identically-named input. A BARE
// RETURN has no name to thread by — so it arrives as `subject`, and a stage
// that wants it declares that slot.
//
// The target this exists for:
//
//     [with]koru/curl:multi.new()
//         |> multi.add(url: "https://…")
//         |> multi.add(url: "https://…")
//         |> multi.start()
//     | started p |> await(p)
//
// with `multi.add { subject: *Multi<!empty|!open>, url: string }`. The thread
// fills `subject`; `url` is written because nothing else can supply it;
// `multi.start()` takes only the thread, so its parentheses are empty. No
// binder anywhere in the chain.
//
// WHY A MAGIC NAME AND NOT A MARKER, and why this one. A marker on the slot
// (`m: *Multi<…>[thread]`) was rejected: there is no principled answer to when
// you would mark and when you would not. The name must also read correctly at
// BOTH sites — threaded AND written out — which is what ruled out `upstream`
// (`do(upstream: some-var)` says nothing true). The thread is not always a
// pointer or an object, which ruled out `ref` and `instance`
// (`bump(ref: 5)`). `self` reads fine but means "method receiver" throughout
// the Zig half of every lift. `subject` survives all three tests and says what
// `self` says without claiming the value is an object.
//
// Here: `seed` bare-returns 1, `bump` adds 10 twice through the thread, and
// only the final value is bound because only it needs a name. Today nothing
// fills `subject`, the intermediate results are discarded, and the seed
// arrives unchanged.
//
// Today's failure mode is itself a host leak: `bump()` with its required slot
// unfilled reaches Zig as `missing struct field: subject`, not a koru
// diagnostic. Whatever fills the thread, an unfilled required argument wants a
// koru sentence — the same class as 210_173 and 400_157.
//
// Sibling of 210_172, which is this from the other side: that pin asks a step's
// RESULT to move forward, this one asks the next stage's SLOT to receive it.
// `[with]` already works and is not pinned here; 210_174 (multi-line chains)
// is what the target above additionally needs.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
proc bump|zig { return subject + 10; }

seed() |> bump() |> bump(): r |> std/io:print.ln("threaded = {{ r:d }}")
