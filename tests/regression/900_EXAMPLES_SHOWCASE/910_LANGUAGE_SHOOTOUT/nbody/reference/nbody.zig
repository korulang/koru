// N-body benchmark - Clean Zig reference
// Uses idiomatic for loops, no special optimizations
const std = @import("std");

const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

const Body = struct {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    mass: f64,
};

fn advance(bodies: []Body, dt: f64) void {
    for (bodies, 0..) |*bi, i| {
        for (bodies[i + 1 ..]) |*bj| {
            const dx = bi.x - bj.x;
            const dy = bi.y - bj.y;
            const dz = bi.z - bj.z;
            const dsq = dx * dx + dy * dy + dz * dz;
            const mag = dt / (dsq * @sqrt(dsq));

            bi.vx -= dx * bj.mass * mag;
            bi.vy -= dy * bj.mass * mag;
            bi.vz -= dz * bj.mass * mag;
            bj.vx += dx * bi.mass * mag;
            bj.vy += dy * bi.mass * mag;
            bj.vz += dz * bi.mass * mag;
        }
    }
    for (bodies) |*b| {
        b.x += dt * b.vx;
        b.y += dt * b.vy;
        b.z += dt * b.vz;
    }
}

fn energy(bodies: []const Body) f64 {
    var e: f64 = 0.0;
    for (bodies, 0..) |b, i| {
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
        for (bodies[i + 1 ..]) |other| {
            const dx = b.x - other.x;
            const dy = b.y - other.y;
            const dz = b.z - other.z;
            e -= (b.mass * other.mass) / @sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

fn offsetMomentum(bodies: []Body) void {
    var px: f64 = 0.0;
    var py: f64 = 0.0;
    var pz: f64 = 0.0;
    for (bodies) |b| {
        px += b.vx * b.mass;
        py += b.vy * b.mass;
        pz += b.vz * b.mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);
    if (args.len < 2) {
        std.debug.print("Usage: nbody <iterations>\n", .{});
        return;
    }
    const n = try std.fmt.parseInt(u32, args[1], 10);

    var bodies = [_]Body{
        .{ .x = 0, .y = 0, .z = 0, .vx = 0, .vy = 0, .vz = 0, .mass = SOLAR_MASS },
        .{ .x = 4.84143144246472090e+00, .y = -1.16032004402742839e+00, .z = -1.03622044471123109e-01, .vx = 1.66007664274403694e-03 * DAYS_PER_YEAR, .vy = 7.69901118419740425e-03 * DAYS_PER_YEAR, .vz = -6.90460016972063023e-05 * DAYS_PER_YEAR, .mass = 9.54791938424326609e-04 * SOLAR_MASS },
        .{ .x = 8.34336671824457987e+00, .y = 4.12479856412430479e+00, .z = -4.03523417114321381e-01, .vx = -2.76742510726862411e-03 * DAYS_PER_YEAR, .vy = 4.99852801234917238e-03 * DAYS_PER_YEAR, .vz = 2.30417297573763929e-05 * DAYS_PER_YEAR, .mass = 2.85885980666130812e-04 * SOLAR_MASS },
        .{ .x = 1.28943695621391310e+01, .y = -1.51111514016986312e+01, .z = -2.23307578892655734e-01, .vx = 2.96460137564761618e-03 * DAYS_PER_YEAR, .vy = 2.37847173959480950e-03 * DAYS_PER_YEAR, .vz = -2.96589568540237556e-05 * DAYS_PER_YEAR, .mass = 4.36624404335156298e-05 * SOLAR_MASS },
        .{ .x = 1.53796971148509165e+01, .y = -2.59193146099879641e+01, .z = 1.79258772950371181e-01, .vx = 2.68067772490389322e-03 * DAYS_PER_YEAR, .vy = 1.62824170038242295e-03 * DAYS_PER_YEAR, .vz = -9.51592254519715870e-05 * DAYS_PER_YEAR, .mass = 5.15138902046611451e-05 * SOLAR_MASS },
    };

    for (0..n) |_| advance(&bodies, 0.01);
    std.debug.print("{d:.9}\n", .{energy(&bodies)});
}
