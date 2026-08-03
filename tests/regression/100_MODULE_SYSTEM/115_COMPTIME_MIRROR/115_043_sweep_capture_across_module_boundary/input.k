// PIN (RED on purpose): a sweep that CAPTURES, where the store lives in a
// DIFFERENT module than the sweep. Measured 2026-08-03:
// `use of undeclared identifier '__koru_store_items'`, raw Zig.
//
// This is the shape a real ECS has — components declared in one module, the
// systems that iterate them in another, each system taking a parameter it
// uses per row. It is what stands between us and a Koru entry in
// tests/benchmarks/003_ecs_reactive.
//
// THE COMBINATION IS THE BUG. Each half is green on its own:
//   - store + capturing sweep in the SAME module            -> runs
//   - store in module A, NON-capturing sweep in module B     -> runs
//   - store in module A, CAPTURING sweep in module B         -> this test
//
// THE MECHANISM, read off the emitted Zig. The store variable is declared in
// its OWN module's namespace (`koru_app.koru_lib.koru_world`). With no
// capture, the sweep's loop is lifted into a `__store_sweeprun_*` event that
// is PLACED IN THAT SAME NAMESPACE, so the bare `__koru_store_items` resolves
// — by coincidence of placement, not because anything qualified it. A capture
// forces the loop to stay INLINE at the sweep site so the captured value is in
// lexical scope, and inline means the CALLER's namespace:
//
//     // emitted inside koru_app.koru_lib.koru_systems
//     for (0..__koru_store_items.len) |__koru_si| {                        // BARE
//         koru_app.koru_lib.koru_world.__store_sweepbody_items_L8_event...  // QUALIFIED
//     }
//
// One emitted statement, two references to things living in `koru_world`, and
// only one of them is qualified. The emitter already knows the body's home —
// it wrote the path — so the store symbol is the half that was never taught.
//
// Which makes this a NAMING-domain fault, not a reachability one: nothing is
// missing from the tree, the pass runs, and the name it emits is simply spelled
// for a namespace it is not in. The capture did not break anything; it removed
// the coincidence that was hiding the bug.
import std/io
import std/store
import app/lib/world
import app/lib/systems

app/lib/world:seed()
app/lib/systems:scale()

std/store:query(items)
! query e |> std/io:print.ln("v {{ e.v:d }}")
