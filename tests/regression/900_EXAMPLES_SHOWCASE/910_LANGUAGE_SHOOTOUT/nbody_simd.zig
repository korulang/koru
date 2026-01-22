// N-BODY with explicit SIMD vectors
//
// Use @Vector(4, f64) for 3D operations (x, y, z, padding)
// AVX gives us 4 f64s per register - perfect for 3D + 1 padding

const std = @import("std");

const PI = 3.141592653589793;
const SOLAR_MASS = 4.0 * PI * PI;
const DAYS_PER_YEAR = 365.24;
const DT = 0.01;
const N = 5;

const Vec3 = @Vector(4, f64); // x, y, z, 0 (padding for AVX alignment)

const Body = struct {
    pos: Vec3,
    vel: Vec3,
    mass: f64,
};

fn vec3(x: f64, y: f64, z: f64) Vec3 {
    return .{ x, y, z, 0 };
}

fn initBodies() [N]Body {
    return .{
        .{ .pos = vec3(0, 0, 0), .vel = vec3(0, 0, 0), .mass = SOLAR_MASS },
        .{ .pos = vec3(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01), .vel = vec3(1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR, -6.90460016972063023e-05 * DAYS_PER_YEAR), .mass = 9.54791938424326609e-04 * SOLAR_MASS },
        .{ .pos = vec3(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01), .vel = vec3(-2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR), .mass = 2.85885980666130812e-04 * SOLAR_MASS },
        .{ .pos = vec3(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01), .vel = vec3(2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR), .mass = 4.36624404335156298e-05 * SOLAR_MASS },
        .{ .pos = vec3(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01), .vel = vec3(2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR), .mass = 5.15138902046611451e-05 * SOLAR_MASS },
    };
}

fn offsetMomentum(bodies: *[N]Body) void {
    var p: Vec3 = @splat(0);
    for (bodies) |b| {
        p += b.vel * @as(Vec3, @splat(b.mass));
    }
    bodies[0].vel = -p / @as(Vec3, @splat(SOLAR_MASS));
}

fn dot(v: Vec3) f64 {
    return v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
}

fn energy(bodies: *const [N]Body) f64 {
    var e: f64 = 0;

    for (bodies, 0..) |b, i| {
        // Kinetic
        e += 0.5 * b.mass * dot(b.vel);

        // Potential
        for (i + 1..N) |j| {
            const d = b.pos - bodies[j].pos;
            e -= (b.mass * bodies[j].mass) / @sqrt(dot(d));
        }
    }

    return e;
}

fn advance(bodies: *[N]Body) void {
    // Velocity updates
    for (0..N) |i| {
        for (i + 1..N) |j| {
            const d = bodies[i].pos - bodies[j].pos;
            const dist_sq = dot(d);
            const mag: Vec3 = @splat(DT / (dist_sq * @sqrt(dist_sq)));

            bodies[i].vel -= d * @as(Vec3, @splat(bodies[j].mass)) * mag;
            bodies[j].vel += d * @as(Vec3, @splat(bodies[i].mass)) * mag;
        }
    }

    // Position updates
    const dt_vec: Vec3 = @splat(DT);
    for (bodies) |*b| {
        b.pos += dt_vec * b.vel;
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

    for (0..n) |_| {
        advance(&bodies);
    }

    std.debug.print("{d:.9}\n", .{energy(&bodies)});
}
