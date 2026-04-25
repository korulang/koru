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
    for (0..@min(world.pos_x.len, 16)) |i| {
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
    for (0..@min(world.active.len, 16)) |i| {
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

fn parseArgs(allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scenario")) {
            const value = args.next() orelse return error.MissingScenario;
            if (std.mem.eql(u8, value, "dense")) config.scenario = .dense else if (std.mem.eql(u8, value, "sparse")) config.scenario = .sparse else if (std.mem.eql(u8, value, "fanout")) config.scenario = .fanout else if (std.mem.eql(u8, value, "spawn")) config.scenario = .spawn else if (std.mem.eql(u8, value, "spawn_batch")) config.scenario = .spawn_batch else if (std.mem.eql(u8, value, "despawn")) config.scenario = .despawn else if (std.mem.eql(u8, value, "add_remove")) config.scenario = .add_remove else if (std.mem.eql(u8, value, "query_get")) config.scenario = .query_get else if (std.mem.eql(u8, value, "schedule_empty")) config.scenario = .schedule_empty else if (std.mem.eql(u8, value, "combat_world")) config.scenario = .combat_world else if (std.mem.eql(u8, value, "bevy_strength_world")) config.scenario = .bevy_strength_world else return error.UnknownScenario;
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
    };
    const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);

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
