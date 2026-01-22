// N-BODY with Rust-style loop splitting
//
// Key insight from Rust: batch operations for better pipelining
// 1. Compute all delta positions
// 2. Compute all magnitudes (batch sqrt)
// 3. Apply all velocity updates
// 4. Update positions

const std = @import("std");

const PI = 3.141592653589793;
const SOLAR_MASS = 4.0 * PI * PI;
const DAYS_PER_YEAR = 365.24;
const DT = 0.01;
const N = 5;
const PAIRS = N * (N - 1) / 2; // 10 pairs

const Body = struct {
    x: f64, y: f64, z: f64,
    vx: f64, vy: f64, vz: f64,
    mass: f64,
};

const Delta = struct { dx: f64, dy: f64, dz: f64 };

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
    for (&bodies) |*b| {
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

// Pre-computed pair indices for the split loop
const pair_i = blk: {
    var arr: [PAIRS]usize = undefined;
    var k: usize = 0;
    for (0..N) |i| {
        for (i + 1..N) |_| {
            arr[k] = i;
            k += 1;
        }
    }
    break :blk arr;
};

const pair_j = blk: {
    var arr: [PAIRS]usize = undefined;
    var k: usize = 0;
    for (0..N) |i| {
        for (i + 1..N) |j| {
            arr[k] = j;
            k += 1;
        }
    }
    break :blk arr;
};

fn advance() void {
    // Pre-allocate for all pairs
    var deltas: [PAIRS]Delta = undefined;
    var mags: [PAIRS]f64 = undefined;

    // Phase 1: Compute all delta positions
    for (0..PAIRS) |k| {
        const i = pair_i[k];
        const j = pair_j[k];
        deltas[k] = .{
            .dx = bodies[i].x - bodies[j].x,
            .dy = bodies[i].y - bodies[j].y,
            .dz = bodies[i].z - bodies[j].z,
        };
    }

    // Phase 2: Compute all magnitudes (batches sqrt)
    for (0..PAIRS) |k| {
        const d = deltas[k];
        const dist_sq = d.dx * d.dx + d.dy * d.dy + d.dz * d.dz;
        mags[k] = DT / (dist_sq * @sqrt(dist_sq));
    }

    // Phase 3: Apply velocity updates
    for (0..PAIRS) |k| {
        const i = pair_i[k];
        const j = pair_j[k];
        const d = deltas[k];
        const mag = mags[k];

        bodies[i].vx -= d.dx * bodies[j].mass * mag;
        bodies[i].vy -= d.dy * bodies[j].mass * mag;
        bodies[i].vz -= d.dz * bodies[j].mass * mag;
        bodies[j].vx += d.dx * bodies[i].mass * mag;
        bodies[j].vy += d.dy * bodies[i].mass * mag;
        bodies[j].vz += d.dz * bodies[i].mass * mag;
    }

    // Phase 4: Update positions
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
