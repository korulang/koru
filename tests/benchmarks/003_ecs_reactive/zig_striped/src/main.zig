const std = @import("std");

const Scenario = enum {
    dense,
    sparse,
    fanout,
    spawn,
    spawn_batch,
    despawn,
    add_remove,
    query_get,
    schedule_empty,
    combat_world,
    bevy_strength_world,
    boids,
    // Instrumented twin of `boids`: identical arithmetic, identical checksum,
    // plus a per-phase nanosecond breakdown on stderr. Not in run.sh.
    boids_phase,
    // Same again, but with hash and scatter as two passes instead of one --
    // the shape the Koru arm is forced into. Same checksum.
    boids_split_hs,
    // Columns as module-level fixed arrays rather than heap slices.
    boids_static,
    // ...and with normalizesafe written as selects instead of an early return.
    boids_static_nsel,
    // Baseline heap slices, but normalizesafe as selects: isolates the shape
    // from the memory model.
    boids_nsel,
};

const Config = struct {
    scenario: Scenario = .dense,
    entities: usize = 100_000,
    frames: usize = 100,
    observers: usize = 25,
};

const World = struct {
    pos_x: []f32,
    pos_y: []f32,
    vel_x: []f32,
    vel_y: []f32,
    health: []i32,
    active: []usize,

    fn init(allocator: std.mem.Allocator, entities: usize) !World {
        var world = World{
            .pos_x = try allocator.alloc(f32, entities),
            .pos_y = try allocator.alloc(f32, entities),
            .vel_x = try allocator.alloc(f32, entities),
            .vel_y = try allocator.alloc(f32, entities),
            .health = try allocator.alloc(i32, entities),
            .active = try allocator.alloc(usize, (entities + 9) / 10),
        };

        var active_count: usize = 0;
        for (0..entities) |i| {
            world.pos_x[i] = @floatFromInt(i);
            world.pos_y[i] = 0;
            world.vel_x[i] = 1;
            world.vel_y[i] = -1;
            world.health[i] = 1000;
            if (i % 10 == 0) {
                world.active[active_count] = i;
                active_count += 1;
            }
        }
        world.active = world.active[0..active_count];
        return world;
    }

    fn deinit(self: World, allocator: std.mem.Allocator) void {
        allocator.free(self.pos_x);
        allocator.free(self.pos_y);
        allocator.free(self.vel_x);
        allocator.free(self.vel_y);
        allocator.free(self.health);
        allocator.free(self.active.ptr[0 .. (self.pos_x.len + 9) / 10]);
    }
};

fn dense(world: *World, frames: usize) u64 {
    var sink: u64 = 0;
    for (0..frames) |_| {
        for (0..world.pos_x.len) |i| {
            world.pos_x[i] += world.vel_x[i];
            world.pos_y[i] += world.vel_y[i];
        }
    }
    // FULL CORPUS. This summed only the first 16 rows, which sampled 0.016%
    // of the work and did not even agree with the bevy anchor's first 16,
    // because "the first 16" depends on iteration order. A wrapping integer
    // add over every row is order-independent and holds across
    // implementations that visit rows in different orders.
    for (0..world.pos_x.len) |i| {
        sink +%= @as(u64, @intFromFloat(world.pos_x[i]));
    }
    return sink;
}

fn sparse(world: *World, frames: usize) u64 {
    var sink: u64 = 0;
    for (0..frames) |_| {
        for (world.active) |i| {
            world.pos_x[i] += world.vel_x[i];
            world.pos_y[i] += world.vel_y[i];
        }
    }
    // FULL CORPUS over the active set — see the note in `dense`.
    for (0..world.active.len) |i| {
        sink +%= @as(u64, @intFromFloat(world.pos_x[world.active[i]]));
    }
    return sink;
}

fn fanout(world: *World, frames: usize, observers: usize) u64 {
    var sink: u64 = 0;
    const events_per_frame = world.health.len / 10;
    for (0..frames) |frame| {
        for (0..events_per_frame) |event_index| {
            const entity = (frame *% 131 + event_index *% 17) % world.health.len;
            world.health[entity] -= 1;
            const value: u64 = @intCast(world.health[entity]);
            for (0..observers) |observer| {
                if (((value ^ observer) *% 0x9e37_79b9) & 7 == 0) {
                    sink +%= value +% observer;
                }
            }
        }
    }
    return sink;
}

fn spawn(allocator: std.mem.Allocator, entities: usize) !u64 {
    var world = try World.init(allocator, entities);
    defer world.deinit(allocator);
    return world.pos_x.len;
}

fn spawnBatch(allocator: std.mem.Allocator, entities: usize) !u64 {
    return spawn(allocator, entities);
}

fn despawn(allocator: std.mem.Allocator, entities: usize) !u64 {
    var world = try World.init(allocator, entities);
    world.deinit(allocator);
    return 0;
}

fn addRemove(allocator: std.mem.Allocator, entities: usize) !u64 {
    const active = try allocator.alloc(bool, entities);
    defer allocator.free(active);

    for (active) |*value| value.* = false;
    for (active) |*value| value.* = true;
    for (active) |*value| value.* = false;
    return entities;
}

fn queryGet(world: *World, frames: usize) u64 {
    var sink: u64 = 0;
    for (0..frames) |_| {
        for (0..world.pos_x.len) |i| {
            sink +%= @as(u64, @intFromFloat(world.pos_x[i]));
        }
    }
    return sink;
}

fn emptySystem(sink: *u64) callconv(.c) void {
    sink.* +%= 1;
    std.mem.doNotOptimizeAway(sink.*);
}

fn scheduleEmpty(frames: usize) u64 {
    var sink: u64 = 0;
    const system: *const fn (*u64) callconv(.c) void = emptySystem;
    for (0..frames) |_| {
        system(&sink);
    }
    return sink;
}

const CombatWorld = struct {
    enemy_x: []f32,
    enemy_y: []f32,
    enemy_health: []i32,
    enemy_alive: []bool,
    projectile_x: []f32,
    projectile_y: []f32,
    projectile_vx: []f32,
    projectile_vy: []f32,
    projectile_alive: []bool,
    buckets: []std.ArrayListUnmanaged(usize),

    const grid_width = 64;
    const cell_size: f32 = 16.0;
    const radius_sq: f32 = 4.0;

    fn init(allocator: std.mem.Allocator, entities: usize) !CombatWorld {
        const enemy_count = entities / 10;
        const projectile_count = entities / 10;
        var world = CombatWorld{
            .enemy_x = try allocator.alloc(f32, enemy_count),
            .enemy_y = try allocator.alloc(f32, enemy_count),
            .enemy_health = try allocator.alloc(i32, enemy_count),
            .enemy_alive = try allocator.alloc(bool, enemy_count),
            .projectile_x = try allocator.alloc(f32, projectile_count),
            .projectile_y = try allocator.alloc(f32, projectile_count),
            .projectile_vx = try allocator.alloc(f32, projectile_count),
            .projectile_vy = try allocator.alloc(f32, projectile_count),
            .projectile_alive = try allocator.alloc(bool, projectile_count),
            .buckets = try allocator.alloc(std.ArrayListUnmanaged(usize), grid_width * grid_width),
        };

        for (0..enemy_count) |i| {
            world.enemy_x[i] = @floatFromInt((i * 37) % 1024);
            world.enemy_x[i] += 0.5;
            world.enemy_y[i] = @floatFromInt((i * 91) % 1024);
            world.enemy_y[i] += 0.5;
            world.enemy_health[i] = 100;
            world.enemy_alive[i] = true;
        }
        for (0..projectile_count) |i| {
            world.projectile_x[i] = @floatFromInt((i * 37) % 1024);
            world.projectile_y[i] = @floatFromInt((i * 91) % 1024);
            world.projectile_vx[i] = if (i % 2 == 0) 0.25 else -0.25;
            world.projectile_vy[i] = if (i % 3 == 0) 0.15 else -0.15;
            world.projectile_alive[i] = true;
        }
        for (world.buckets) |*bucket| {
            bucket.* = .{};
        }
        return world;
    }

    fn deinit(self: *CombatWorld, allocator: std.mem.Allocator) void {
        allocator.free(self.enemy_x);
        allocator.free(self.enemy_y);
        allocator.free(self.enemy_health);
        allocator.free(self.enemy_alive);
        allocator.free(self.projectile_x);
        allocator.free(self.projectile_y);
        allocator.free(self.projectile_vx);
        allocator.free(self.projectile_vy);
        allocator.free(self.projectile_alive);
        for (self.buckets) |*bucket| {
            bucket.deinit(allocator);
        }
        allocator.free(self.buckets);
    }

    fn bucketIndex(x: f32, y: f32) usize {
        const max: isize = grid_width - 1;
        const bx = std.math.clamp(@as(isize, @intFromFloat(@floor(x / cell_size))), 0, max);
        const by = std.math.clamp(@as(isize, @intFromFloat(@floor(y / cell_size))), 0, max);
        return @as(usize, @intCast(by)) * grid_width + @as(usize, @intCast(bx));
    }

    fn rebuildBuckets(self: *CombatWorld, allocator: std.mem.Allocator) !void {
        for (self.buckets) |*bucket| {
            bucket.clearRetainingCapacity();
        }
        for (0..self.enemy_x.len) |enemy| {
            if (!self.enemy_alive[enemy]) continue;
            const index = bucketIndex(self.enemy_x[enemy], self.enemy_y[enemy]);
            try self.buckets[index].append(allocator, enemy);
        }
    }

    fn run(self: *CombatWorld, allocator: std.mem.Allocator, frames: usize, observers: usize) !u64 {
        var sink: u64 = 0;
        for (0..frames) |_| {
            for (0..self.projectile_x.len) |projectile| {
                if (!self.projectile_alive[projectile]) continue;
                self.projectile_x[projectile] += self.projectile_vx[projectile];
                self.projectile_y[projectile] += self.projectile_vy[projectile];
            }

            try self.rebuildBuckets(allocator);

            for (0..self.projectile_x.len) |projectile| {
                if (!self.projectile_alive[projectile]) continue;
                const index = bucketIndex(self.projectile_x[projectile], self.projectile_y[projectile]);
                for (self.buckets[index].items) |enemy| {
                    if (!self.enemy_alive[enemy]) continue;
                    const dx = self.projectile_x[projectile] - self.enemy_x[enemy];
                    const dy = self.projectile_y[projectile] - self.enemy_y[enemy];
                    if (dx * dx + dy * dy <= radius_sq) {
                        self.projectile_alive[projectile] = false;
                        self.enemy_health[enemy] -= 10;
                        const value: u64 = @intCast(self.enemy_health[enemy]);
                        for (0..observers) |observer| {
                            if (((value ^ observer) *% 0x9e37_79b9) & 7 == 0) {
                                sink +%= value +% observer;
                            }
                        }
                        if (self.enemy_health[enemy] <= 0) {
                            self.enemy_alive[enemy] = false;
                        }
                        break;
                    }
                }
            }
        }
        return sink;
    }
};

fn combatWorld(allocator: std.mem.Allocator, entities: usize, frames: usize, observers: usize) !u64 {
    var world = try CombatWorld.init(allocator, entities);
    defer world.deinit(allocator);
    return world.run(allocator, frames, observers);
}

const BevyStrengthWorld = struct {
    dyn_pos_x: []f32,
    dyn_pos_y: []f32,
    dyn_vel_x: []f32,
    dyn_vel_y: []f32,
    dyn_acc_x: []f32,
    dyn_acc_y: []f32,
    particle_pos_x: []f32,
    particle_pos_y: []f32,
    particle_vel_x: []f32,
    particle_vel_y: []f32,
    particle_lifetime: []i32,
    particle_alive: []bool,
    orbiter_pos_x: []f32,
    orbiter_pos_y: []f32,
    orbiter_phase: []f32,
    orbiter_radius: []f32,
    orbiter_speed: []f32,

    fn init(allocator: std.mem.Allocator, entities: usize) !BevyStrengthWorld {
        const dynamic_count = entities / 2;
        const particle_count = entities / 4;
        const orbiter_count = entities - dynamic_count - particle_count;
        var world = BevyStrengthWorld{
            .dyn_pos_x = try allocator.alloc(f32, dynamic_count),
            .dyn_pos_y = try allocator.alloc(f32, dynamic_count),
            .dyn_vel_x = try allocator.alloc(f32, dynamic_count),
            .dyn_vel_y = try allocator.alloc(f32, dynamic_count),
            .dyn_acc_x = try allocator.alloc(f32, dynamic_count),
            .dyn_acc_y = try allocator.alloc(f32, dynamic_count),
            .particle_pos_x = try allocator.alloc(f32, particle_count),
            .particle_pos_y = try allocator.alloc(f32, particle_count),
            .particle_vel_x = try allocator.alloc(f32, particle_count),
            .particle_vel_y = try allocator.alloc(f32, particle_count),
            .particle_lifetime = try allocator.alloc(i32, particle_count),
            .particle_alive = try allocator.alloc(bool, particle_count),
            .orbiter_pos_x = try allocator.alloc(f32, orbiter_count),
            .orbiter_pos_y = try allocator.alloc(f32, orbiter_count),
            .orbiter_phase = try allocator.alloc(f32, orbiter_count),
            .orbiter_radius = try allocator.alloc(f32, orbiter_count),
            .orbiter_speed = try allocator.alloc(f32, orbiter_count),
        };

        for (0..dynamic_count) |i| {
            world.dyn_pos_x[i] = @floatFromInt(i % 2048);
            world.dyn_pos_y[i] = @floatFromInt((i * 7) % 2048);
            world.dyn_vel_x[i] = (@as(f32, @floatFromInt(i % 13)) - 6.0) * 0.01;
            world.dyn_vel_y[i] = (@as(f32, @floatFromInt(i % 17)) - 8.0) * 0.01;
            world.dyn_acc_x[i] = (@as(f32, @floatFromInt(i % 5)) - 2.0) * 0.001;
            world.dyn_acc_y[i] = (@as(f32, @floatFromInt(i % 7)) - 3.0) * 0.001;
        }
        for (0..particle_count) |i| {
            world.particle_pos_x[i] = @floatFromInt(i % 1024);
            world.particle_pos_y[i] = @floatFromInt((i * 11) % 1024);
            world.particle_vel_x[i] = (@as(f32, @floatFromInt(i % 9)) - 4.0) * 0.03;
            world.particle_vel_y[i] = (@as(f32, @floatFromInt(i % 15)) - 7.0) * 0.03;
            world.particle_lifetime[i] = 1000 + @as(i32, @intCast(i % 1000));
            world.particle_alive[i] = true;
        }
        for (0..orbiter_count) |i| {
            world.orbiter_pos_x[i] = 0;
            world.orbiter_pos_y[i] = 0;
            world.orbiter_phase[i] = @as(f32, @floatFromInt(i)) * 0.001;
            world.orbiter_radius[i] = 10.0 + @as(f32, @floatFromInt(i % 100));
            world.orbiter_speed[i] = 0.001 + @as(f32, @floatFromInt(i % 11)) * 0.0001;
        }
        return world;
    }

    fn deinit(self: *BevyStrengthWorld, allocator: std.mem.Allocator) void {
        allocator.free(self.dyn_pos_x);
        allocator.free(self.dyn_pos_y);
        allocator.free(self.dyn_vel_x);
        allocator.free(self.dyn_vel_y);
        allocator.free(self.dyn_acc_x);
        allocator.free(self.dyn_acc_y);
        allocator.free(self.particle_pos_x);
        allocator.free(self.particle_pos_y);
        allocator.free(self.particle_vel_x);
        allocator.free(self.particle_vel_y);
        allocator.free(self.particle_lifetime);
        allocator.free(self.particle_alive);
        allocator.free(self.orbiter_pos_x);
        allocator.free(self.orbiter_pos_y);
        allocator.free(self.orbiter_phase);
        allocator.free(self.orbiter_radius);
        allocator.free(self.orbiter_speed);
    }

    fn run(self: *BevyStrengthWorld, frames: usize) u64 {
        var sink: u64 = 0;
        for (0..frames) |_| {
            for (0..self.dyn_pos_x.len) |i| {
                self.dyn_vel_x[i] = (self.dyn_vel_x[i] + self.dyn_acc_x[i]) * 0.999;
                self.dyn_vel_y[i] = (self.dyn_vel_y[i] + self.dyn_acc_y[i]) * 0.999;
                self.dyn_pos_x[i] += self.dyn_vel_x[i];
                self.dyn_pos_y[i] += self.dyn_vel_y[i];
                if (self.dyn_pos_x[i] < 0 or self.dyn_pos_x[i] > 2048) {
                    self.dyn_vel_x[i] = -self.dyn_vel_x[i] * 0.8;
                    self.dyn_pos_x[i] = std.math.clamp(self.dyn_pos_x[i], 0, 2048);
                }
                if (self.dyn_pos_y[i] < 0 or self.dyn_pos_y[i] > 2048) {
                    self.dyn_vel_y[i] = -self.dyn_vel_y[i] * 0.8;
                    self.dyn_pos_y[i] = std.math.clamp(self.dyn_pos_y[i], 0, 2048);
                }
                sink +%= @as(u64, @intFromFloat(@abs(self.dyn_pos_x[i]))) *% 31;
                sink +%= @as(u64, @intFromFloat(@abs(self.dyn_pos_y[i]))) *% 17;
            }

            for (0..self.particle_pos_x.len) |i| {
                if (!self.particle_alive[i]) continue;
                self.particle_pos_x[i] += self.particle_vel_x[i];
                self.particle_pos_y[i] += self.particle_vel_y[i];
                self.particle_lifetime[i] -= 1;
                if (self.particle_lifetime[i] <= 0) {
                    self.particle_alive[i] = false;
                }
                sink +%= @as(u64, @intFromFloat(@abs(self.particle_pos_x[i]))) *% 31;
                sink +%= @as(u64, @intFromFloat(@abs(self.particle_pos_y[i]))) *% 17;
            }

            for (0..self.orbiter_pos_x.len) |i| {
                self.orbiter_phase[i] += self.orbiter_speed[i];
                self.orbiter_pos_x[i] = self.orbiter_radius[i] * @cos(self.orbiter_phase[i]);
                self.orbiter_pos_y[i] = self.orbiter_radius[i] * @sin(self.orbiter_phase[i]);
                sink +%= @as(u64, @intFromFloat(@abs(self.orbiter_pos_x[i]))) *% 31;
                sink +%= @as(u64, @intFromFloat(@abs(self.orbiter_pos_y[i]))) *% 17;
            }
        }
        return sink;
    }
};

fn bevyStrengthWorld(allocator: std.mem.Allocator, entities: usize, frames: usize) !u64 {
    var world = try BevyStrengthWorld.init(allocator, entities);
    defer world.deinit(allocator);
    return world.run(frames);
}

// Port of Unity DOTS `BoidSystem.cs`. The constants, the phase order and the
// checksum are a contract shared bit-for-bit with the bevy and Koru arms, so
// every expression below is written in the order the contract states: f32
// addition is not associative and a reordering is a different sink.
const Vec3 = struct { x: f32, y: f32, z: f32 };

fn lengthsq(x: f32, y: f32, z: f32) f32 {
    return x * x + y * y + z * z;
}

// `1.0 / sqrt(len)` and then multiply -- NOT `x / sqrt(len)`. The two round
// differently and the cross-arm checksum would diverge.
fn normalizesafe(x: f32, y: f32, z: f32) Vec3 {
    const flt_min_normal: f32 = 1.1754944e-38;
    const len = lengthsq(x, y, z);
    if (len > flt_min_normal) {
        const inv = 1.0 / @sqrt(len);
        return .{ .x = x * inv, .y = y * inv, .z = z * inv };
    }
    return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
}

// The SAME function with the early return replaced by three per-component
// selects -- which is the shape koru's emitter produces, because it has no way
// to name a shared subexpression and writes the guard out once per component.
// Identical value for every input reachable here; the checksum is the oracle.
fn normalizesafeSel(x: f32, y: f32, z: f32) Vec3 {
    const flt_min_normal: f32 = 1.1754944e-38;
    const len = lengthsq(x, y, z);
    const ok = len > flt_min_normal;
    const inv = 1.0 / @sqrt(len);
    return .{
        .x = if (ok) x * inv else 0.0,
        .y = if (ok) y * inv else 0.0,
        .z = if (ok) z * inv else 0.0,
    };
}

const BoidWorld = struct {
    pos_x: []f32,
    pos_y: []f32,
    pos_z: []f32,
    fwd_x: []f32,
    fwd_y: []f32,
    fwd_z: []f32,
    cell: []usize,
    cell_count: []i64,
    cell_a_x: []f32,
    cell_a_y: []f32,
    cell_a_z: []f32,
    cell_s_x: []f32,
    cell_s_y: []f32,
    cell_s_z: []f32,
    cell_target: []i64,
    cell_obstacle_dist: []f32,

    // DOTS' own authoring defaults, unscaled.
    const cell_radius: f32 = 8.0;
    const axis_cells = 32;
    const cell_total = axis_cells * axis_cells * axis_cells;
    const separation_weight: f32 = 1.0;
    const alignment_weight: f32 = 1.0;
    const target_weight: f32 = 2.0;
    const aversion: f32 = 30.0;
    const move_speed: f32 = 25.0;
    const dt: f32 = 1.0 / 60.0;
    const move_dist: f32 = move_speed * dt;
    const n_targets = 2;
    const n_obstacles = 1;
    const pos_max: f32 = 255.999;

    fn init(allocator: std.mem.Allocator, entities: usize) !BoidWorld {
        var world = BoidWorld{
            .pos_x = try allocator.alloc(f32, entities),
            .pos_y = try allocator.alloc(f32, entities),
            .pos_z = try allocator.alloc(f32, entities),
            .fwd_x = try allocator.alloc(f32, entities),
            .fwd_y = try allocator.alloc(f32, entities),
            .fwd_z = try allocator.alloc(f32, entities),
            .cell = try allocator.alloc(usize, entities),
            .cell_count = try allocator.alloc(i64, cell_total),
            .cell_a_x = try allocator.alloc(f32, cell_total),
            .cell_a_y = try allocator.alloc(f32, cell_total),
            .cell_a_z = try allocator.alloc(f32, cell_total),
            .cell_s_x = try allocator.alloc(f32, cell_total),
            .cell_s_y = try allocator.alloc(f32, cell_total),
            .cell_s_z = try allocator.alloc(f32, cell_total),
            .cell_target = try allocator.alloc(i64, cell_total),
            .cell_obstacle_dist = try allocator.alloc(f32, cell_total),
        };

        for (0..entities) |i| {
            world.pos_x[i] = @floatFromInt(i % 256);
            world.pos_y[i] = @floatFromInt((i / 256) % 256);
            world.pos_z[i] = @floatFromInt((i / 65536) % 256);
            const forward = normalizesafe(
                @as(f32, @floatFromInt(i % 13)) - 6.0,
                @as(f32, @floatFromInt(i % 17)) - 8.0,
                @as(f32, @floatFromInt(i % 7)) - 3.0,
            );
            world.fwd_x[i] = forward.x;
            world.fwd_y[i] = forward.y;
            world.fwd_z[i] = forward.z;
            world.cell[i] = 0;
        }
        return world;
    }

    fn deinit(self: *BoidWorld, allocator: std.mem.Allocator) void {
        allocator.free(self.pos_x);
        allocator.free(self.pos_y);
        allocator.free(self.pos_z);
        allocator.free(self.fwd_x);
        allocator.free(self.fwd_y);
        allocator.free(self.fwd_z);
        allocator.free(self.cell);
        allocator.free(self.cell_count);
        allocator.free(self.cell_a_x);
        allocator.free(self.cell_a_y);
        allocator.free(self.cell_a_z);
        allocator.free(self.cell_s_x);
        allocator.free(self.cell_s_y);
        allocator.free(self.cell_s_z);
        allocator.free(self.cell_target);
        allocator.free(self.cell_obstacle_dist);
    }

    // Per-phase accumulator for the `boids_phase` twin. `timed` is comptime,
    // so the `boids` instantiation is the original loop with no clock in it.
    const PhaseTimer = struct {
        ph: [5]u64 = .{0} ** 5,
        prev: std.time.Instant = undefined,
        fn begin(pt: *PhaseTimer, comptime timed: bool) void {
            if (timed) pt.prev = std.time.Instant.now() catch unreachable;
        }
        fn mark(pt: *PhaseTimer, comptime timed: bool, comptime slot: usize) void {
            if (!timed) return;
            const now = std.time.Instant.now() catch unreachable;
            pt.ph[slot] += now.since(pt.prev);
            pt.prev = now;
        }
    };

    fn run(self: *BoidWorld, frames: usize, comptime timed: bool, comptime split_hs: bool, comptime nsel: bool, pt: *PhaseTimer) void {
        const nsfn = if (nsel) normalizesafeSel else normalizesafe;
        for (0..frames) |frame| {
            pt.begin(timed);
            // Sawtooth target and obstacle motion -- no trigonometry, because
            // libm sin/cos differ in the last ulp between toolchains.
            const targets = [n_targets]Vec3{
                .{ .x = @floatFromInt((frame * 3) % 256), .y = 128.0, .z = @floatFromInt((frame * 5) % 256) },
                .{ .x = @floatFromInt((frame * 7) % 256), .y = 160.0, .z = @floatFromInt((frame * 11) % 256) },
            };
            const obstacles = [n_obstacles]Vec3{
                .{ .x = @floatFromInt((frame * 13) % 256), .y = 128.0, .z = @floatFromInt((frame * 17) % 256) },
            };
            pt.mark(timed, 0);

            // Phase 1: clear. Every cell, unconditionally. DOTS reallocates a
            // sparse hash map per frame instead; we hold a dense 32^3 grid.
            for (0..cell_total) |c| {
                self.cell_count[c] = 0;
                self.cell_a_x[c] = 0;
                self.cell_a_y[c] = 0;
                self.cell_a_z[c] = 0;
                self.cell_s_x[c] = 0;
                self.cell_s_y[c] = 0;
                self.cell_s_z[c] = 0;
                self.cell_target[c] = 0;
                self.cell_obstacle_dist[c] = 0;
            }
            pt.mark(timed, 1);

            // Phase 2: hash + scatter, in boid insertion order. Sequential
            // accumulation -- a different order is a different checksum.
            if (split_hs) {
                // The Koru arm spells these as two store sweeps rather than one.
                // Same visit order, same accumulation order, same checksum.
                for (0..self.pos_x.len) |i| {
                    const cx = std.math.clamp(@as(i64, @intFromFloat(self.pos_x[i] / cell_radius)), 0, axis_cells - 1);
                    const cy = std.math.clamp(@as(i64, @intFromFloat(self.pos_y[i] / cell_radius)), 0, axis_cells - 1);
                    const cz = std.math.clamp(@as(i64, @intFromFloat(self.pos_z[i] / cell_radius)), 0, axis_cells - 1);
                    self.cell[i] = @intCast((cz * axis_cells + cy) * axis_cells + cx);
                }
                for (0..self.pos_x.len) |i| {
                    const idx = self.cell[i];
                    self.cell_count[idx] += 1;
                    self.cell_a_x[idx] += self.fwd_x[i];
                    self.cell_a_y[idx] += self.fwd_y[i];
                    self.cell_a_z[idx] += self.fwd_z[i];
                    self.cell_s_x[idx] += self.pos_x[i];
                    self.cell_s_y[idx] += self.pos_y[i];
                    self.cell_s_z[idx] += self.pos_z[i];
                }
            } else for (0..self.pos_x.len) |i| {
                const cx = std.math.clamp(@as(i64, @intFromFloat(self.pos_x[i] / cell_radius)), 0, axis_cells - 1);
                const cy = std.math.clamp(@as(i64, @intFromFloat(self.pos_y[i] / cell_radius)), 0, axis_cells - 1);
                const cz = std.math.clamp(@as(i64, @intFromFloat(self.pos_z[i] / cell_radius)), 0, axis_cells - 1);
                const idx: usize = @intCast((cz * axis_cells + cy) * axis_cells + cx);
                self.cell[i] = idx;
                self.cell_count[idx] += 1;
                self.cell_a_x[idx] += self.fwd_x[i];
                self.cell_a_y[idx] += self.fwd_y[i];
                self.cell_a_z[idx] += self.fwd_z[i];
                self.cell_s_x[idx] += self.pos_x[i];
                self.cell_s_y[idx] += self.pos_y[i];
                self.cell_s_z[idx] += self.pos_z[i];
            }
            pt.mark(timed, 2);

            // Phase 3: cell resolve (DOTS' MergeCells) -- per cell, not per
            // boid. argmin ties go to the lower index.
            for (0..cell_total) |c| {
                const count = self.cell_count[c];
                if (count <= 0) continue;
                const n: f32 = @floatFromInt(count);
                const avg_x = self.cell_s_x[c] / n;
                const avg_y = self.cell_s_y[c] / n;
                const avg_z = self.cell_s_z[c] / n;

                var nearest_target: i64 = 0;
                var nearest_target_dist = lengthsq(targets[0].x - avg_x, targets[0].y - avg_y, targets[0].z - avg_z);
                for (1..n_targets) |t| {
                    const dist = lengthsq(targets[t].x - avg_x, targets[t].y - avg_y, targets[t].z - avg_z);
                    if (dist < nearest_target_dist) {
                        nearest_target_dist = dist;
                        nearest_target = @intCast(t);
                    }
                }

                var nearest_obstacle_dist = lengthsq(obstacles[0].x - avg_x, obstacles[0].y - avg_y, obstacles[0].z - avg_z);
                for (1..n_obstacles) |o| {
                    const dist = lengthsq(obstacles[o].x - avg_x, obstacles[o].y - avg_y, obstacles[o].z - avg_z);
                    if (dist < nearest_obstacle_dist) nearest_obstacle_dist = dist;
                }

                self.cell_target[c] = nearest_target;
                self.cell_obstacle_dist[c] = @sqrt(nearest_obstacle_dist);
            }
            pt.mark(timed, 3);

            // Phase 4: steer, in boid insertion order. The cell index comes
            // from phase 2 -- nothing has moved since.
            for (0..self.pos_x.len) |i| {
                const idx = self.cell[i];
                const pos_x = self.pos_x[i];
                const pos_y = self.pos_y[i];
                const pos_z = self.pos_z[i];
                const fwd_x = self.fwd_x[i];
                const fwd_y = self.fwd_y[i];
                const fwd_z = self.fwd_z[i];
                const n: f32 = @floatFromInt(self.cell_count[idx]);

                const alignment = nsfn(
                    self.cell_a_x[idx] / n - fwd_x,
                    self.cell_a_y[idx] / n - fwd_y,
                    self.cell_a_z[idx] / n - fwd_z,
                );
                const separation = nsfn(
                    pos_x * n - self.cell_s_x[idx],
                    pos_y * n - self.cell_s_y[idx],
                    pos_z * n - self.cell_s_z[idx],
                );
                const target = targets[@as(usize, @intCast(self.cell_target[idx]))];
                const heading = nsfn(target.x - pos_x, target.y - pos_y, target.z - pos_z);

                const obstacle = obstacles[0];
                const obstacle_steering = nsfn(pos_x - obstacle.x, pos_y - obstacle.y, pos_z - obstacle.z);
                const avoid_x = (obstacle.x + obstacle_steering.x * aversion) - pos_x;
                const avoid_y = (obstacle.y + obstacle_steering.y * aversion) - pos_y;
                const avoid_z = (obstacle.z + obstacle_steering.z * aversion) - pos_z;

                const normal = nsfn(
                    alignment_weight * alignment.x + separation_weight * separation.x + target_weight * heading.x,
                    alignment_weight * alignment.y + separation_weight * separation.y + target_weight * heading.y,
                    alignment_weight * alignment.z + separation_weight * separation.z + target_weight * heading.z,
                );

                const avoiding = (self.cell_obstacle_dist[idx] - aversion) < 0.0;
                const forward_x = if (avoiding) avoid_x else normal.x;
                const forward_y = if (avoiding) avoid_y else normal.y;
                const forward_z = if (avoiding) avoid_z else normal.z;

                const next = nsfn(
                    fwd_x + dt * (forward_x - fwd_x),
                    fwd_y + dt * (forward_y - fwd_y),
                    fwd_z + dt * (forward_z - fwd_z),
                );
                self.fwd_x[i] = next.x;
                self.fwd_y[i] = next.y;
                self.fwd_z[i] = next.z;
                self.pos_x[i] = std.math.clamp(pos_x + next.x * move_dist, 0.0, pos_max);
                self.pos_y[i] = std.math.clamp(pos_y + next.y * move_dist, 0.0, pos_max);
                self.pos_z[i] = std.math.clamp(pos_z + next.z * move_dist, 0.0, pos_max);
            }
            pt.mark(timed, 4);
        }
    }

    fn checksum(self: *const BoidWorld) u64 {
        var sink: u64 = 0;
        for (0..self.pos_x.len) |i| {
            sink +%= @as(u64, @intFromFloat(@abs(self.pos_x[i]))) *% 31;
            sink +%= @as(u64, @intFromFloat(@abs(self.pos_y[i]))) *% 17;
            sink +%= @as(u64, @intFromFloat(@abs(self.pos_z[i]))) *% 13;
        }
        return sink;
    }
};


// ----------------------------------------------------------------------------
// `boids_static`: the SAME frame, byte-identical arithmetic, with every column
// as a MODULE-LEVEL fixed-extent array instead of a slice on a heap struct.
// This is the one property koru's emitted Zig has that no other arm does: the
// columns live at LINK-TIME addresses with comptime extents, not behind a
// runtime base pointer. Legion's test-3 transplant used a BOXED struct of fixed
// arrays -- comptime extents but a runtime base -- so it did not cover this.
// Same toolchain, same body, one variable. Not in run.sh.
const static_cap: usize = 100_000;
var g_pos_x: [static_cap]f32 = undefined;
var g_pos_y: [static_cap]f32 = undefined;
var g_pos_z: [static_cap]f32 = undefined;
var g_fwd_x: [static_cap]f32 = undefined;
var g_fwd_y: [static_cap]f32 = undefined;
var g_fwd_z: [static_cap]f32 = undefined;
var g_cell: [static_cap]usize = undefined;
var g_cell_count: [BoidWorld.cell_total]i64 = undefined;
var g_cell_a_x: [BoidWorld.cell_total]f32 = undefined;
var g_cell_a_y: [BoidWorld.cell_total]f32 = undefined;
var g_cell_a_z: [BoidWorld.cell_total]f32 = undefined;
var g_cell_s_x: [BoidWorld.cell_total]f32 = undefined;
var g_cell_s_y: [BoidWorld.cell_total]f32 = undefined;
var g_cell_s_z: [BoidWorld.cell_total]f32 = undefined;
var g_cell_target: [BoidWorld.cell_total]i64 = undefined;
var g_cell_obstacle_dist: [BoidWorld.cell_total]f32 = undefined;

const StaticBoids = struct {
    const cell_radius = BoidWorld.cell_radius;
    const axis_cells = BoidWorld.axis_cells;
    const cell_total = BoidWorld.cell_total;
    const separation_weight = BoidWorld.separation_weight;
    const alignment_weight = BoidWorld.alignment_weight;
    const target_weight = BoidWorld.target_weight;
    const aversion = BoidWorld.aversion;
    const move_speed = BoidWorld.move_speed;
    const dt = BoidWorld.dt;
    const move_dist = BoidWorld.move_dist;
    const n_targets = BoidWorld.n_targets;
    const n_obstacles = BoidWorld.n_obstacles;
    const pos_max = BoidWorld.pos_max;
    const PhaseTimer = BoidWorld.PhaseTimer;

    fn init() void {
        for (0..static_cap) |i| {
            g_pos_x[i] = @floatFromInt(i % 256);
            g_pos_y[i] = @floatFromInt((i / 256) % 256);
            g_pos_z[i] = @floatFromInt((i / 65536) % 256);
            const forward = normalizesafe(
                @as(f32, @floatFromInt(i % 13)) - 6.0,
                @as(f32, @floatFromInt(i % 17)) - 8.0,
                @as(f32, @floatFromInt(i % 7)) - 3.0,
            );
            g_fwd_x[i] = forward.x;
            g_fwd_y[i] = forward.y;
            g_fwd_z[i] = forward.z;
            g_cell[i] = 0;
        }
    }

    fn checksum() u64 {
        var sink: u64 = 0;
        for (0..static_cap) |i| {
            sink +%= @as(u64, @intFromFloat(@abs(g_pos_x[i]))) *% 31;
            sink +%= @as(u64, @intFromFloat(@abs(g_pos_y[i]))) *% 17;
            sink +%= @as(u64, @intFromFloat(@abs(g_pos_z[i]))) *% 13;
        }
        return sink;
    }

    fn runStatic(frames: usize, comptime timed: bool, comptime nsel: bool, pt: *PhaseTimer) void {
        const nsfn = if (nsel) normalizesafeSel else normalizesafe;
        for (0..frames) |frame| {
            pt.begin(timed);
            // Sawtooth target and obstacle motion -- no trigonometry, because
            // libm sin/cos differ in the last ulp between toolchains.
            const targets = [n_targets]Vec3{
                .{ .x = @floatFromInt((frame * 3) % 256), .y = 128.0, .z = @floatFromInt((frame * 5) % 256) },
                .{ .x = @floatFromInt((frame * 7) % 256), .y = 160.0, .z = @floatFromInt((frame * 11) % 256) },
            };
            const obstacles = [n_obstacles]Vec3{
                .{ .x = @floatFromInt((frame * 13) % 256), .y = 128.0, .z = @floatFromInt((frame * 17) % 256) },
            };
            pt.mark(timed, 0);

            // Phase 1: clear. Every cell, unconditionally. DOTS reallocates a
            // sparse hash map per frame instead; we hold a dense 32^3 grid.
            for (0..cell_total) |c| {
                g_cell_count[c] = 0;
                g_cell_a_x[c] = 0;
                g_cell_a_y[c] = 0;
                g_cell_a_z[c] = 0;
                g_cell_s_x[c] = 0;
                g_cell_s_y[c] = 0;
                g_cell_s_z[c] = 0;
                g_cell_target[c] = 0;
                g_cell_obstacle_dist[c] = 0;
            }
            pt.mark(timed, 1);

            // Phase 2: hash + scatter, in boid insertion order. Sequential
            // accumulation -- a different order is a different checksum.
            for (0..static_cap) |i| {
                const cx = std.math.clamp(@as(i64, @intFromFloat(g_pos_x[i] / cell_radius)), 0, axis_cells - 1);
                const cy = std.math.clamp(@as(i64, @intFromFloat(g_pos_y[i] / cell_radius)), 0, axis_cells - 1);
                const cz = std.math.clamp(@as(i64, @intFromFloat(g_pos_z[i] / cell_radius)), 0, axis_cells - 1);
                const idx: usize = @intCast((cz * axis_cells + cy) * axis_cells + cx);
                g_cell[i] = idx;
                g_cell_count[idx] += 1;
                g_cell_a_x[idx] += g_fwd_x[i];
                g_cell_a_y[idx] += g_fwd_y[i];
                g_cell_a_z[idx] += g_fwd_z[i];
                g_cell_s_x[idx] += g_pos_x[i];
                g_cell_s_y[idx] += g_pos_y[i];
                g_cell_s_z[idx] += g_pos_z[i];
            }
            pt.mark(timed, 2);

            // Phase 3: cell resolve (DOTS' MergeCells) -- per cell, not per
            // boid. argmin ties go to the lower index.
            for (0..cell_total) |c| {
                const count = g_cell_count[c];
                if (count <= 0) continue;
                const n: f32 = @floatFromInt(count);
                const avg_x = g_cell_s_x[c] / n;
                const avg_y = g_cell_s_y[c] / n;
                const avg_z = g_cell_s_z[c] / n;

                var nearest_target: i64 = 0;
                var nearest_target_dist = lengthsq(targets[0].x - avg_x, targets[0].y - avg_y, targets[0].z - avg_z);
                for (1..n_targets) |t| {
                    const dist = lengthsq(targets[t].x - avg_x, targets[t].y - avg_y, targets[t].z - avg_z);
                    if (dist < nearest_target_dist) {
                        nearest_target_dist = dist;
                        nearest_target = @intCast(t);
                    }
                }

                var nearest_obstacle_dist = lengthsq(obstacles[0].x - avg_x, obstacles[0].y - avg_y, obstacles[0].z - avg_z);
                for (1..n_obstacles) |o| {
                    const dist = lengthsq(obstacles[o].x - avg_x, obstacles[o].y - avg_y, obstacles[o].z - avg_z);
                    if (dist < nearest_obstacle_dist) nearest_obstacle_dist = dist;
                }

                g_cell_target[c] = nearest_target;
                g_cell_obstacle_dist[c] = @sqrt(nearest_obstacle_dist);
            }
            pt.mark(timed, 3);

            // Phase 4: steer, in boid insertion order. The cell index comes
            // from phase 2 -- nothing has moved since.
            for (0..static_cap) |i| {
                const idx = g_cell[i];
                const pos_x = g_pos_x[i];
                const pos_y = g_pos_y[i];
                const pos_z = g_pos_z[i];
                const fwd_x = g_fwd_x[i];
                const fwd_y = g_fwd_y[i];
                const fwd_z = g_fwd_z[i];
                const n: f32 = @floatFromInt(g_cell_count[idx]);

                const alignment = nsfn(
                    g_cell_a_x[idx] / n - fwd_x,
                    g_cell_a_y[idx] / n - fwd_y,
                    g_cell_a_z[idx] / n - fwd_z,
                );
                const separation = nsfn(
                    pos_x * n - g_cell_s_x[idx],
                    pos_y * n - g_cell_s_y[idx],
                    pos_z * n - g_cell_s_z[idx],
                );
                const target = targets[@as(usize, @intCast(g_cell_target[idx]))];
                const heading = nsfn(target.x - pos_x, target.y - pos_y, target.z - pos_z);

                const obstacle = obstacles[0];
                const obstacle_steering = nsfn(pos_x - obstacle.x, pos_y - obstacle.y, pos_z - obstacle.z);
                const avoid_x = (obstacle.x + obstacle_steering.x * aversion) - pos_x;
                const avoid_y = (obstacle.y + obstacle_steering.y * aversion) - pos_y;
                const avoid_z = (obstacle.z + obstacle_steering.z * aversion) - pos_z;

                const normal = nsfn(
                    alignment_weight * alignment.x + separation_weight * separation.x + target_weight * heading.x,
                    alignment_weight * alignment.y + separation_weight * separation.y + target_weight * heading.y,
                    alignment_weight * alignment.z + separation_weight * separation.z + target_weight * heading.z,
                );

                const avoiding = (g_cell_obstacle_dist[idx] - aversion) < 0.0;
                const forward_x = if (avoiding) avoid_x else normal.x;
                const forward_y = if (avoiding) avoid_y else normal.y;
                const forward_z = if (avoiding) avoid_z else normal.z;

                const next = nsfn(
                    fwd_x + dt * (forward_x - fwd_x),
                    fwd_y + dt * (forward_y - fwd_y),
                    fwd_z + dt * (forward_z - fwd_z),
                );
                g_fwd_x[i] = next.x;
                g_fwd_y[i] = next.y;
                g_fwd_z[i] = next.z;
                g_pos_x[i] = std.math.clamp(pos_x + next.x * move_dist, 0.0, pos_max);
                g_pos_y[i] = std.math.clamp(pos_y + next.y * move_dist, 0.0, pos_max);
                g_pos_z[i] = std.math.clamp(pos_z + next.z * move_dist, 0.0, pos_max);
            }
            pt.mark(timed, 4);
        }
    }

};

fn boidsStatic(entities: usize, frames: usize, elapsed_ns: *u64, comptime nsel: bool) !u64 {
    if (entities != static_cap) return error.UnknownArgument;
    StaticBoids.init();
    var pt = BoidWorld.PhaseTimer{};
    const start = std.time.nanoTimestamp();
    StaticBoids.runStatic(frames, true, nsel, &pt);
    elapsed_ns.* = @intCast(std.time.nanoTimestamp() - start);
    const names = [_][]const u8{ "actors", "clear", "hash+scatter", "resolve", "steer" };
    for (names, pt.ph) |nm, v| {
        std.debug.print("zig_striped {s} {s}: {d} ns ({d:.3} ms)\n", .{ if (nsel) "boids_static_nsel" else "boids_static", nm, v, @as(f64, @floatFromInt(v)) / 1_000_000.0 });
    }
    return StaticBoids.checksum();
}

fn boids(allocator: std.mem.Allocator, entities: usize, frames: usize, elapsed_ns: *u64, comptime timed: bool, comptime split_hs: bool, comptime nsel: bool) !u64 {
    var world = try BoidWorld.init(allocator, entities);
    defer world.deinit(allocator);
    var pt = BoidWorld.PhaseTimer{};
    const start = std.time.nanoTimestamp();
    world.run(frames, timed, split_hs, nsel, &pt);
    elapsed_ns.* = @intCast(std.time.nanoTimestamp() - start);
    if (timed) {
        const names = [_][]const u8{ "actors", "clear", "hash+scatter", "resolve", "steer" };
        var total: u64 = 0;
        for (pt.ph) |v| total += v;
        for (names, pt.ph) |nm, v| {
            std.debug.print("zig_striped boids_phase {s}: {d} ns ({d:.3} ms)\n", .{ nm, v, @as(f64, @floatFromInt(v)) / 1_000_000.0 });
        }
        std.debug.print("zig_striped boids_phase phase_total: {d} ns ({d:.3} ms)\n", .{ total, @as(f64, @floatFromInt(total)) / 1_000_000.0 });
    }
    return world.checksum();
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scenario")) {
            const value = args.next() orelse return error.MissingScenario;
            // Checked ahead of the chain below so that line stays untouched.
            if (std.mem.eql(u8, value, "boids_phase")) {
                config.scenario = .boids_phase;
                continue;
            }
            if (std.mem.eql(u8, value, "boids_split_hs")) {
                config.scenario = .boids_split_hs;
                continue;
            }
            if (std.mem.eql(u8, value, "boids_nsel")) {
                config.scenario = .boids_nsel;
                continue;
            }
            if (std.mem.eql(u8, value, "boids_static_nsel")) {
                config.scenario = .boids_static_nsel;
                continue;
            }
            if (std.mem.eql(u8, value, "boids_static")) {
                config.scenario = .boids_static;
                continue;
            }
            if (std.mem.eql(u8, value, "dense")) config.scenario = .dense else if (std.mem.eql(u8, value, "sparse")) config.scenario = .sparse else if (std.mem.eql(u8, value, "fanout")) config.scenario = .fanout else if (std.mem.eql(u8, value, "spawn")) config.scenario = .spawn else if (std.mem.eql(u8, value, "spawn_batch")) config.scenario = .spawn_batch else if (std.mem.eql(u8, value, "despawn")) config.scenario = .despawn else if (std.mem.eql(u8, value, "add_remove")) config.scenario = .add_remove else if (std.mem.eql(u8, value, "query_get")) config.scenario = .query_get else if (std.mem.eql(u8, value, "schedule_empty")) config.scenario = .schedule_empty else if (std.mem.eql(u8, value, "combat_world")) config.scenario = .combat_world else if (std.mem.eql(u8, value, "bevy_strength_world")) config.scenario = .bevy_strength_world else if (std.mem.eql(u8, value, "boids")) config.scenario = .boids else return error.UnknownScenario;
        } else if (std.mem.eql(u8, arg, "--entities")) {
            config.entities = try std.fmt.parseInt(usize, args.next() orelse return error.MissingEntities, 10);
        } else if (std.mem.eql(u8, arg, "--frames")) {
            config.frames = try std.fmt.parseInt(usize, args.next() orelse return error.MissingFrames, 10);
        } else if (std.mem.eql(u8, arg, "--observers")) {
            config.observers = try std.fmt.parseInt(usize, args.next() orelse return error.MissingObservers, 10);
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const config = try parseArgs(allocator);
    // `boids` times only its frame loop -- its init is outside the timed
    // region by contract -- so it reports its own elapsed and main uses that
    // in place of the whole-call span.
    var boids_elapsed_ns: u64 = 0;
    const start = std.time.nanoTimestamp();
    const sink = switch (config.scenario) {
        .dense, .sparse, .fanout, .query_get => blk: {
            var world = try World.init(allocator, config.entities);
            defer world.deinit(allocator);
            break :blk switch (config.scenario) {
                .dense => dense(&world, config.frames),
                .sparse => sparse(&world, config.frames),
                .fanout => fanout(&world, config.frames, config.observers),
                .query_get => queryGet(&world, config.frames),
                else => unreachable,
            };
        },
        .spawn => try spawn(allocator, config.entities),
        .spawn_batch => try spawnBatch(allocator, config.entities),
        .despawn => try despawn(allocator, config.entities),
        .add_remove => try addRemove(allocator, config.entities),
        .schedule_empty => scheduleEmpty(config.frames),
        .combat_world => try combatWorld(allocator, config.entities, config.frames, config.observers),
        .bevy_strength_world => try bevyStrengthWorld(allocator, config.entities, config.frames),
        .boids => try boids(allocator, config.entities, config.frames, &boids_elapsed_ns, false, false, false),
        .boids_phase => try boids(allocator, config.entities, config.frames, &boids_elapsed_ns, true, false, false),
        .boids_split_hs => try boids(allocator, config.entities, config.frames, &boids_elapsed_ns, true, true, false),
        .boids_nsel => try boids(allocator, config.entities, config.frames, &boids_elapsed_ns, true, false, true),
        .boids_static => try boidsStatic(config.entities, config.frames, &boids_elapsed_ns, false),
        .boids_static_nsel => try boidsStatic(config.entities, config.frames, &boids_elapsed_ns, true),
    };
    const elapsed: u64 = switch (config.scenario) {
        .boids, .boids_phase, .boids_split_hs, .boids_static, .boids_static_nsel, .boids_nsel => boids_elapsed_ns,
        else => @intCast(std.time.nanoTimestamp() - start),
    };

    const scenario_name = switch (config.scenario) {
        .dense => "dense",
        .sparse => "sparse",
        .fanout => "fanout",
        .spawn => "spawn",
        .spawn_batch => "spawn_batch",
        .despawn => "despawn",
        .add_remove => "add_remove",
        .query_get => "query_get",
        .schedule_empty => "schedule_empty",
        .combat_world => "combat_world",
        .bevy_strength_world => "bevy_strength_world",
        .boids => "boids",
        .boids_phase => "boids_phase",
        .boids_split_hs => "boids_split_hs",
        .boids_static => "boids_static",
        .boids_static_nsel => "boids_static_nsel",
        .boids_nsel => "boids_nsel",
    };
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_file.interface;
    try stdout.print("{{\"impl\":\"zig_striped\",\"scenario\":\"{s}\",\"entities\":{},\"frames\":{},\"observers\":{},\"elapsed_ns\":{},\"sink\":{}}}\n", .{
        scenario_name,
        config.entities,
        config.frames,
        config.observers,
        elapsed,
        sink,
    });
    try stdout.flush();
}
