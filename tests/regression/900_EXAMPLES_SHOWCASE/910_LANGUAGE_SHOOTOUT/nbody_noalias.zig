// N-BODY with explicit noalias hints
//
// Hypothesis: Rust wins because borrow checker proves non-aliasing.
// Try: Use Zig's restrict/noalias patterns to help LLVM.

const std = @import("std");

const PI = 3.141592653589793;
const SOLAR_MASS = 4.0 * PI * PI;
const DAYS_PER_YEAR = 365.24;
const DT = 0.01;
const N = 5;

const Body = struct {
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    mass: f64,
};

var bodies: [N]Body = .{
    .{ .x = 0, .y = 0, .z = 0, .vx = 0, .vy = 0, .vz = 0, .mass = SOLAR_MASS },
    .{ .x = 4.84143144246472090e+00, .y = -1.16032004402742839e+00, .z = -1.03622044471123109e-01, .vx = 1.66007664274403694e-03 * DAYS_PER_YEAR, .vy = 7.69901118419740425e-03 * DAYS_PER_YEAR, .vz = -6.90460016972063023e-05 * DAYS_PER_YEAR, .mass = 9.54791938424326609e-04 * SOLAR_MASS },
    .{ .x = 8.34336671824457987e+00, .y = 4.12479856412430479e+00, .z = -4.03523417114321381e-01, .vx = -2.76742510726862411e-03 * DAYS_PER_YEAR, .vy = 4.99852801234917238e-03 * DAYS_PER_YEAR, .vz = 2.30417297573763929e-05 * DAYS_PER_YEAR, .mass = 2.85885980666130812e-04 * SOLAR_MASS },
    .{ .x = 1.28943695621391310e+01, .y = -1.51111514016986312e+01, .z = -2.23307578892655734e-01, .vx = 2.96460137564761618e-03 * DAYS_PER_YEAR, .vy = 2.37847173959480950e-03 * DAYS_PER_YEAR, .vz = -2.96589568540237556e-05 * DAYS_PER_YEAR, .mass = 4.36624404335156298e-05 * SOLAR_MASS },
    .{ .x = 1.53796971148509165e+01, .y = -2.59193146099879641e+01, .z = 1.79258772950371181e-01, .vx = 2.68067772490389322e-03 * DAYS_PER_YEAR, .vy = 1.62824170038242295e-03 * DAYS_PER_YEAR, .vz = -9.51592254519715870e-05 * DAYS_PER_YEAR, .mass = 5.15138902046611451e-05 * SOLAR_MASS },
};

fn offsetMomentum() void {
    var px: f64 = 0;
    var py: f64 = 0;
    var pz: f64 = 0;
    for (&bodies) |b| {
        px += b.vx * b.mass;
        py += b.vy * b.mass;
        pz += b.vz * b.mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
}

fn energy() f64 {
    var e: f64 = 0;
    for (bodies, 0..) |b, i| {
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for (i + 1..N) |j| {
            const dx = b.x - bodies[j].x;
            const dy = b.y - bodies[j].y;
            const dz = b.z - bodies[j].z;
            e -= (b.mass * bodies[j].mass) / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

// Key insight: Use separate pointers that Zig can prove don't alias
inline fn updatePair(b1: *Body, b2: *Body) void {
    const dx = b1.x - b2.x;
    const dy = b1.y - b2.y;
    const dz = b1.z - b2.z;
    const dist_sq = dx * dx + dy * dy + dz * dz;
    const mag = DT / (dist_sq * @sqrt(dist_sq));

    const m1 = b1.mass;
    const m2 = b2.mass;

    b1.vx -= dx * m2 * mag;
    b1.vy -= dy * m2 * mag;
    b1.vz -= dz * m2 * mag;
    b2.vx += dx * m1 * mag;
    b2.vy += dy * m1 * mag;
    b2.vz += dz * m1 * mag;
}

fn advance() void {
    // Mimic Rust's split_first_mut pattern - give optimizer separate pointers
    updatePair(&bodies[0], &bodies[1]);
    updatePair(&bodies[0], &bodies[2]);
    updatePair(&bodies[0], &bodies[3]);
    updatePair(&bodies[0], &bodies[4]);
    updatePair(&bodies[1], &bodies[2]);
    updatePair(&bodies[1], &bodies[3]);
    updatePair(&bodies[1], &bodies[4]);
    updatePair(&bodies[2], &bodies[3]);
    updatePair(&bodies[2], &bodies[4]);
    updatePair(&bodies[3], &bodies[4]);

    // Position updates
    for (&bodies) |*b| {
        b.x += DT * b.vx;
        b.y += DT * b.vy;
        b.z += DT * b.vz;
    }
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: nbody <iterations>\n", .{});
        return;
    }

    const n = try std.fmt.parseInt(u32, args[1], 10);

    offsetMomentum();
    std.debug.print("{d:.9}\n", .{energy()});

    for (0..n) |_| {
        advance();
    }

    std.debug.print("{d:.9}\n", .{energy()});
}
