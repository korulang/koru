// N-BODY with precomputed mass vectors
//
// Avoid @splat on every iteration by storing mass as Vec3

const std = @import("std");

const PI = 3.141592653589793;
const SOLAR_MASS = 4.0 * PI * PI;
const DAYS_PER_YEAR = 365.24;
const DT = 0.01;
const DT_VEC: Vec3 = @splat(DT);
const N = 5;

const Vec3 = @Vector(4, f64);

const Body = struct {
    pos: Vec3,
    vel: Vec3,
    mass_vec: Vec3, // Pre-splatted mass
    mass: f64,      // Scalar for energy calc
};

fn vec3(x: f64, y: f64, z: f64) Vec3 {
    return .{ x, y, z, 0 };
}

fn makeBody(x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64) Body {
    return .{
        .pos = vec3(x, y, z),
        .vel = vec3(vx, vy, vz),
        .mass_vec = @splat(mass),
        .mass = mass,
    };
}

var bodies: [N]Body = .{
    makeBody(0, 0, 0, 0, 0, 0, SOLAR_MASS),
    makeBody(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR, -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS),
    makeBody(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS),
    makeBody(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS),
    makeBody(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS),
};

fn offsetMomentum() void {
    var p: Vec3 = @splat(0);
    for (&bodies) |*b| {
        p += b.vel * b.mass_vec;
    }
    bodies[0].vel = -p / bodies[0].mass_vec;
}

inline fn dot(v: Vec3) f64 {
    return v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
}

fn energy() f64 {
    var e: f64 = 0;
    for (bodies, 0..) |b, i| {
        e += 0.5 * b.mass * dot(b.vel);
        for (i + 1..N) |j| {
            const d = b.pos - bodies[j].pos;
            e -= (b.mass * bodies[j].mass) / @sqrt(dot(d));
        }
    }
    return e;
}

fn advance() void {
    for (0..N) |i| {
        for (i + 1..N) |j| {
            const d = bodies[i].pos - bodies[j].pos;
            const dist_sq = dot(d);
            const mag: Vec3 = @splat(DT / (dist_sq * @sqrt(dist_sq)));
            const d_mag = d * mag;

            bodies[i].vel -= d_mag * bodies[j].mass_vec;
            bodies[j].vel += d_mag * bodies[i].mass_vec;
        }
    }

    for (&bodies) |*b| {
        b.pos += DT_VEC * b.vel;
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
