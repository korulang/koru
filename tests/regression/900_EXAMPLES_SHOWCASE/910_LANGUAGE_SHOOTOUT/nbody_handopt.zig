// HAND-OPTIMIZED N-BODY: Target for Koru kernel codegen
//
// Optimizations applied:
// 1. SoA layout (all x's together, all y's together, etc.)
// 2. Full loop unrolling (10 pairs hardcoded)
// 3. Register-friendly (35 f64s = 280 bytes, fits in registers)
// 4. Minimal memory traffic (compute in registers, write once)
// 5. Newton's 3rd law (compute pair once, update both)
//
// Build: zig build-exe nbody_handopt.zig -O ReleaseFast -femit-bin=nbody-handopt

const std = @import("std");

const PI = 3.141592653589793;
const SOLAR_MASS = 4.0 * PI * PI;
const DAYS_PER_YEAR = 365.24;
const DT = 0.01;

// SoA layout - all coordinates contiguous for SIMD
const Bodies = struct {
    x: [5]f64,
    y: [5]f64,
    z: [5]f64,
    vx: [5]f64,
    vy: [5]f64,
    vz: [5]f64,
    mass: [5]f64,
};

fn initBodies() Bodies {
    return .{
        .x = .{ 0, 4.84143144246472090e+00, 8.34336671824457987e+00, 1.28943695621391310e+01, 1.53796971148509165e+01 },
        .y = .{ 0, -1.16032004402742839e+00, 4.12479856412430479e+00, -1.51111514016986312e+01, -2.59193146099879641e+01 },
        .z = .{ 0, -1.03622044471123109e-01, -4.03523417114321381e-01, -2.23307578892655734e-01, 1.79258772950371181e-01 },
        .vx = .{ 0, 1.66007664274403694e-03 * DAYS_PER_YEAR, -2.76742510726862411e-03 * DAYS_PER_YEAR, 2.96460137564761618e-03 * DAYS_PER_YEAR, 2.68067772490389322e-03 * DAYS_PER_YEAR },
        .vy = .{ 0, 7.69901118419740425e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR },
        .vz = .{ 0, -6.90460016972063023e-05 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR },
        .mass = .{ SOLAR_MASS, 9.54791938424326609e-04 * SOLAR_MASS, 2.85885980666130812e-04 * SOLAR_MASS, 4.36624404335156298e-05 * SOLAR_MASS, 5.15138902046611451e-05 * SOLAR_MASS },
    };
}

fn offsetMomentum(b: *Bodies) void {
    var px: f64 = 0;
    var py: f64 = 0;
    var pz: f64 = 0;
    inline for (0..5) |i| {
        px += b.vx[i] * b.mass[i];
        py += b.vy[i] * b.mass[i];
        pz += b.vz[i] * b.mass[i];
    }
    b.vx[0] = -px / SOLAR_MASS;
    b.vy[0] = -py / SOLAR_MASS;
    b.vz[0] = -pz / SOLAR_MASS;
}

fn energy(b: *const Bodies) f64 {
    var e: f64 = 0;

    // Kinetic energy - unrolled
    inline for (0..5) |i| {
        e += 0.5 * b.mass[i] * (b.vx[i] * b.vx[i] + b.vy[i] * b.vy[i] + b.vz[i] * b.vz[i]);
    }

    // Potential energy - all 10 pairs unrolled
    inline for (0..5) |i| {
        inline for (i + 1..5) |j| {
            const dx = b.x[i] - b.x[j];
            const dy = b.y[i] - b.y[j];
            const dz = b.z[i] - b.z[j];
            e -= (b.mass[i] * b.mass[j]) / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }

    return e;
}

// The hot loop - fully unrolled, all pairs explicit
inline fn advanceOnce(b: *Bodies) void {
    // Compute all 10 pair interactions with full unrolling
    // Pair (0,1)
    {
        const dx = b.x[0] - b.x[1];
        const dy = b.y[0] - b.y[1];
        const dz = b.z[0] - b.z[1];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[0] -= dx * b.mass[1] * mag;
        b.vy[0] -= dy * b.mass[1] * mag;
        b.vz[0] -= dz * b.mass[1] * mag;
        b.vx[1] += dx * b.mass[0] * mag;
        b.vy[1] += dy * b.mass[0] * mag;
        b.vz[1] += dz * b.mass[0] * mag;
    }
    // Pair (0,2)
    {
        const dx = b.x[0] - b.x[2];
        const dy = b.y[0] - b.y[2];
        const dz = b.z[0] - b.z[2];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[0] -= dx * b.mass[2] * mag;
        b.vy[0] -= dy * b.mass[2] * mag;
        b.vz[0] -= dz * b.mass[2] * mag;
        b.vx[2] += dx * b.mass[0] * mag;
        b.vy[2] += dy * b.mass[0] * mag;
        b.vz[2] += dz * b.mass[0] * mag;
    }
    // Pair (0,3)
    {
        const dx = b.x[0] - b.x[3];
        const dy = b.y[0] - b.y[3];
        const dz = b.z[0] - b.z[3];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[0] -= dx * b.mass[3] * mag;
        b.vy[0] -= dy * b.mass[3] * mag;
        b.vz[0] -= dz * b.mass[3] * mag;
        b.vx[3] += dx * b.mass[0] * mag;
        b.vy[3] += dy * b.mass[0] * mag;
        b.vz[3] += dz * b.mass[0] * mag;
    }
    // Pair (0,4)
    {
        const dx = b.x[0] - b.x[4];
        const dy = b.y[0] - b.y[4];
        const dz = b.z[0] - b.z[4];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[0] -= dx * b.mass[4] * mag;
        b.vy[0] -= dy * b.mass[4] * mag;
        b.vz[0] -= dz * b.mass[4] * mag;
        b.vx[4] += dx * b.mass[0] * mag;
        b.vy[4] += dy * b.mass[0] * mag;
        b.vz[4] += dz * b.mass[0] * mag;
    }
    // Pair (1,2)
    {
        const dx = b.x[1] - b.x[2];
        const dy = b.y[1] - b.y[2];
        const dz = b.z[1] - b.z[2];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[1] -= dx * b.mass[2] * mag;
        b.vy[1] -= dy * b.mass[2] * mag;
        b.vz[1] -= dz * b.mass[2] * mag;
        b.vx[2] += dx * b.mass[1] * mag;
        b.vy[2] += dy * b.mass[1] * mag;
        b.vz[2] += dz * b.mass[1] * mag;
    }
    // Pair (1,3)
    {
        const dx = b.x[1] - b.x[3];
        const dy = b.y[1] - b.y[3];
        const dz = b.z[1] - b.z[3];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[1] -= dx * b.mass[3] * mag;
        b.vy[1] -= dy * b.mass[3] * mag;
        b.vz[1] -= dz * b.mass[3] * mag;
        b.vx[3] += dx * b.mass[1] * mag;
        b.vy[3] += dy * b.mass[1] * mag;
        b.vz[3] += dz * b.mass[1] * mag;
    }
    // Pair (1,4)
    {
        const dx = b.x[1] - b.x[4];
        const dy = b.y[1] - b.y[4];
        const dz = b.z[1] - b.z[4];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[1] -= dx * b.mass[4] * mag;
        b.vy[1] -= dy * b.mass[4] * mag;
        b.vz[1] -= dz * b.mass[4] * mag;
        b.vx[4] += dx * b.mass[1] * mag;
        b.vy[4] += dy * b.mass[1] * mag;
        b.vz[4] += dz * b.mass[1] * mag;
    }
    // Pair (2,3)
    {
        const dx = b.x[2] - b.x[3];
        const dy = b.y[2] - b.y[3];
        const dz = b.z[2] - b.z[3];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[2] -= dx * b.mass[3] * mag;
        b.vy[2] -= dy * b.mass[3] * mag;
        b.vz[2] -= dz * b.mass[3] * mag;
        b.vx[3] += dx * b.mass[2] * mag;
        b.vy[3] += dy * b.mass[2] * mag;
        b.vz[3] += dz * b.mass[2] * mag;
    }
    // Pair (2,4)
    {
        const dx = b.x[2] - b.x[4];
        const dy = b.y[2] - b.y[4];
        const dz = b.z[2] - b.z[4];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[2] -= dx * b.mass[4] * mag;
        b.vy[2] -= dy * b.mass[4] * mag;
        b.vz[2] -= dz * b.mass[4] * mag;
        b.vx[4] += dx * b.mass[2] * mag;
        b.vy[4] += dy * b.mass[2] * mag;
        b.vz[4] += dz * b.mass[2] * mag;
    }
    // Pair (3,4)
    {
        const dx = b.x[3] - b.x[4];
        const dy = b.y[3] - b.y[4];
        const dz = b.z[3] - b.z[4];
        const dist_sq = dx * dx + dy * dy + dz * dz;
        const mag = DT / (dist_sq * @sqrt(dist_sq));
        b.vx[3] -= dx * b.mass[4] * mag;
        b.vy[3] -= dy * b.mass[4] * mag;
        b.vz[3] -= dz * b.mass[4] * mag;
        b.vx[4] += dx * b.mass[3] * mag;
        b.vy[4] += dy * b.mass[3] * mag;
        b.vz[4] += dz * b.mass[3] * mag;
    }

    // Update positions - unrolled
    inline for (0..5) |i| {
        b.x[i] += DT * b.vx[i];
        b.y[i] += DT * b.vy[i];
        b.z[i] += DT * b.vz[i];
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

    var bodies = initBodies();
    offsetMomentum(&bodies);

    std.debug.print("{d:.9}\n", .{energy(&bodies)});

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        advanceOnce(&bodies);
    }

    std.debug.print("{d:.9}\n", .{energy(&bodies)});
}
