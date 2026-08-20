const app = @import("output_emitted.zig");

// Unikraft's boot calls this instead of `main`, which is why the emitted `main`
// is dead code in this image — and why the leak check used to ship here and
// never run. It is a `pub fn` now precisely so an entry point that is not `main`
// can still close the run out.
//
// What it reports is a moment, not a culprit: "something was still outstanding
// when this run ended". The count is over raw allocations, which have no type
// and no owner to name. The proofs that name things are settled at compile time
// a level up; this is an independent audit of them, and on a machine with no
// debugger under it, knowing THAT a run leaked is the difference between a
// number you can act on and silence.
export fn koru_main() void {
    app.main_module.koru_start_flow();
    app.main_module.flow0();
    app.main_module.koru_end_flow();
    app.koru_leak_check();
}
