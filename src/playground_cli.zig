//! Native CLI entry. The playground compile pipeline lives in playground.zig
//! (shared as the `playground` module); this is just the thin exe root so the
//! same core can also back the freestanding wasm layer (playground_wasm.zig).
const pg = @import("playground");

pub fn main() !void {
    try pg.main();
}
