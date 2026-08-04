// `scan` — iteration that STOPS. `for` visits every element; `scan` breaks the
// moment its `keep:` expression goes false.
//
// WHY THE LANGUAGE NEEDED IT: `for` was the only loop form. No `while`, and
// `break` exists only as an arbitrary BRANCH NAME. A bounded traversal that
// wanted to stop early had to run its full bound with every iteration guarded
// into a no-op, so a linked-structure walk cost the BOUND rather than the
// LENGTH. Found porting `combat_world`, whose collision step walks a bucket
// chain and stops at the first enemy inside the radius.
//
// WHY `keep:` IS A PARAMETER AND NOT A `when` GUARD ON THE ARM: the first design
// put the stop condition in `when`, and KORU050 refused it — a when-guarded arm
// with no unguarded sibling is a fire where every guard can be false and nothing
// happens, silently. That refusal was right, and not an obstacle to route
// around: it caught `when` being given a SECOND meaning. `when` filters which
// fires are handled; `keep:` terminates iteration. One glyph, one meaning.
//
// BOTH HALVES ARE PINNED HERE. A stop that never fires is indistinguishable from
// a loop that never ran, so the test asserts the STOPPING case AND the
// always-true case that must behave exactly like `for`.
import std/io
import std/store
import std/control

std/store:new(w) { seen: 0[i64], sum: 0[i64] }
std/store:new(u) { n: 0[i64] }

// Stops once `seen` reaches 5 — iterations 5..19 never run, so the sum is
// 0+1+2+3+4 and not 0..19.
tor limited {}
limited = scan(0..20, keep: w.seen < 5)
    ! each i |> std/store:stored { w.seen: w.seen + 1, w.sum: w.sum + @as(i64, @intCast(i)) }

// An always-true `keep:` is exactly `for`: the keyword invents no stop it was
// not given.
tor full {}
full = scan(0..20, keep: 1 == 1)
    ! each _ |> std/store:stored { u.n: u.n + 1 }

limited()
    |> full()
    |> std/io:print.ln("stopped seen {{ w.seen:d }} sum {{ w.sum:d }} full {{ u.n:d }}")
