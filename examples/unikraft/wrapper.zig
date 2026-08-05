// C-ABI seam between Unikraft's boot path and Koru's emitted flow.
//
// Deliberately does NOT call output_emitted.zig's `pub fn main` — that epilogue
// ends in std.process.exit for the leak check, which has no implementation on
// x86_64-freestanding. The three flow functions are exactly what main calls
// before that point.
const app = @import("output_emitted.zig");

export fn koru_main() void {
    app.main_module.koru_start_flow();
    app.main_module.flow0();
    app.main_module.koru_end_flow();
}
