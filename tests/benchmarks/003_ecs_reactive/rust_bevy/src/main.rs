use bevy_ecs::prelude::*;
use std::time::Instant;

#[derive(Clone, Copy)]
enum Scenario {
    Dense,
    Sparse,
    Fanout,
    Spawn,
    SpawnBatch,
    Despawn,
    AddRemove,
    QueryGet,
    ScheduleEmpty,
    CombatWorld,
    BevyStrengthWorld,
    ArchetypeChurnWorld,
    Boids,
}

struct Config {
    scenario: Scenario,
    entities: usize,
    frames: usize,
    observers: usize,
}

#[derive(Component)]
struct Position {
    x: f32,
    y: f32,
}

#[derive(Component)]
struct Velocity {
    x: f32,
    y: f32,
}

#[derive(Component)]
struct Health(i32);

#[derive(Component)]
struct Active;

#[derive(Component)]
struct DynamicBody;

#[derive(Component)]
struct Enemy;

#[derive(Component)]
struct Projectile;

#[derive(Component)]
struct Particle;

#[derive(Component)]
struct Orbiter;

#[derive(Component)]
struct AgentId(usize);

#[derive(Component)]
struct Idle;

#[derive(Component)]
struct Seeking;

#[derive(Component)]
struct Attacking;

#[derive(Component)]
struct Stunned;

#[derive(Component)]
struct Dead;

#[derive(Component)]
struct TargetIndex(usize);

#[derive(Component)]
struct AttackCooldown(i32);

#[derive(Component)]
struct StunTimer(i32);

#[derive(Component)]
struct Acceleration {
    x: f32,
    y: f32,
}

#[derive(Component)]
struct Drag(f32);

#[derive(Component)]
struct Lifetime(i32);

#[derive(Component)]
struct Bounds {
    min: f32,
    max: f32,
}

#[derive(Component)]
struct Orbit {
    phase: f32,
    radius: f32,
    speed: f32,
}

#[derive(Component)]
struct BoidPosition {
    x: f32,
    y: f32,
    z: f32,
}

#[derive(Component)]
struct BoidForward {
    x: f32,
    y: f32,
    z: f32,
}

// The cell a boid hashed into in phase 2, reused verbatim in phase 4: the
// position has not moved in between, so rehashing would only risk drifting
// from the other arms.
#[derive(Component)]
struct CellIndex(usize);

#[derive(Resource)]
struct EntityList(Vec<Entity>);

#[derive(Resource)]
struct Workload {
    frame: usize,
    events_per_frame: usize,
    observers: usize,
}

#[derive(Resource, Default)]
struct Sink(u64);

#[derive(Clone, Copy)]
struct DamageEvent {
    enemy: Entity,
    projectile: Entity,
    damage: i32,
}

#[derive(Resource)]
struct CombatConfig {
    grid_width: usize,
    cell_size: f32,
    radius_sq: f32,
    observers: usize,
}

#[derive(Resource)]
struct SpatialBuckets(Vec<Vec<Entity>>);

#[derive(Resource, Default)]
struct DamageQueue(Vec<DamageEvent>);

#[derive(Resource, Default)]
struct FanoutQueue(Vec<i32>);

#[derive(Resource, Default)]
struct ChurnFrame(usize);

#[derive(Resource, Default)]
struct ChurnStats {
    transitions: u64,
    damage_events: u64,
    deaths: u64,
    checksum: u64,
}

#[derive(Resource)]
struct ChurnEntities(Vec<Entity>);

// The boid grid is a DENSE bounded 32^3 grid, not per-entity data, so it is a
// resource. Struct-of-arrays because every phase touches one field across many
// cells. DOTS hashes into an unbounded NativeParallelMultiHashMap and
// reallocates it per frame; we clamp into a fixed grid and clear it instead,
// which is why phase 1 exists at all.
#[derive(Resource)]
struct BoidCells {
    count: Vec<i64>,
    ax: Vec<f32>,
    ay: Vec<f32>,
    az: Vec<f32>,
    sx: Vec<f32>,
    sy: Vec<f32>,
    sz: Vec<f32>,
    ti: Vec<i64>,
    od: Vec<f32>,
}

impl Default for BoidCells {
    fn default() -> Self {
        Self {
            count: vec![0; BOID_CELL_COUNT],
            ax: vec![0.0; BOID_CELL_COUNT],
            ay: vec![0.0; BOID_CELL_COUNT],
            az: vec![0.0; BOID_CELL_COUNT],
            sx: vec![0.0; BOID_CELL_COUNT],
            sy: vec![0.0; BOID_CELL_COUNT],
            sz: vec![0.0; BOID_CELL_COUNT],
            ti: vec![0; BOID_CELL_COUNT],
            od: vec![0.0; BOID_CELL_COUNT],
        }
    }
}

#[derive(Resource, Default)]
struct BoidFlock {
    frame: i64,
    targets: [[f32; 3]; BOID_N_TARGETS],
    obstacles: [[f32; 3]; BOID_N_OBSTACLES],
}

// Increments a counter, matching the zig baseline's `emptySystem(*u64)` and
// koru's `tick()`. It used to be a genuinely empty body against their
// non-empty ones, so the three were not running the same system and the
// hardcoded sink of 0 could never have revealed it.
fn empty_system(mut sink: ResMut<Sink>) {
    sink.0 = sink.0.wrapping_add(1);
}

fn dense_update(mut query: Query<(&mut Position, &Velocity)>) {
    for (mut pos, vel) in &mut query {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

fn sparse_update(mut query: Query<(&mut Position, &Velocity), With<Active>>) {
    for (mut pos, vel) in &mut query {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

fn damage_system(
    mut health: Query<&mut Health>,
    entities: Res<EntityList>,
    mut workload: ResMut<Workload>,
) {
    let len = entities.0.len();
    for i in 0..workload.events_per_frame {
        let index = (workload.frame.wrapping_mul(131) + i.wrapping_mul(17)) % len;
        if let Ok(mut health) = health.get_mut(entities.0[index]) {
            health.0 -= 1;
        }
    }
    workload.frame = workload.frame.wrapping_add(1);
}

fn fanout_system(query: Query<&Health, Changed<Health>>, workload: Res<Workload>, mut sink: ResMut<Sink>) {
    for health in &query {
        let value = health.0 as u64;
        for observer in 0..workload.observers {
            if ((value ^ observer as u64).wrapping_mul(0x9e37_79b9)) & 7 == 0 {
                sink.0 = sink.0.wrapping_add(value).wrapping_add(observer as u64);
            }
        }
    }
}

fn clear_combat_queues(mut damage: ResMut<DamageQueue>, mut fanout: ResMut<FanoutQueue>) {
    damage.0.clear();
    fanout.0.clear();
}

fn move_projectiles(mut query: Query<(&mut Position, &Velocity), With<Projectile>>) {
    for (mut pos, vel) in &mut query {
        pos.x += vel.x;
        pos.y += vel.y;
    }
}

fn bucket_index(pos: &Position, config: &CombatConfig) -> usize {
    let max = config.grid_width as isize - 1;
    let x = ((pos.x / config.cell_size).floor() as isize).clamp(0, max) as usize;
    let y = ((pos.y / config.cell_size).floor() as isize).clamp(0, max) as usize;
    y * config.grid_width + x
}

fn rebuild_buckets(
    config: Res<CombatConfig>,
    mut buckets: ResMut<SpatialBuckets>,
    enemies: Query<(Entity, &Position), With<Enemy>>,
) {
    for bucket in &mut buckets.0 {
        bucket.clear();
    }
    for (entity, pos) in &enemies {
        let index = bucket_index(pos, &config);
        buckets.0[index].push(entity);
    }
}

fn collide_projectiles(
    config: Res<CombatConfig>,
    buckets: Res<SpatialBuckets>,
    projectiles: Query<(Entity, &Position), With<Projectile>>,
    enemies: Query<&Position, With<Enemy>>,
    mut damage: ResMut<DamageQueue>,
) {
    for (projectile, projectile_pos) in &projectiles {
        let index = bucket_index(projectile_pos, &config);
        for enemy in &buckets.0[index] {
            let Ok(enemy_pos) = enemies.get(*enemy) else {
                continue;
            };
            let dx = projectile_pos.x - enemy_pos.x;
            let dy = projectile_pos.y - enemy_pos.y;
            if dx * dx + dy * dy <= config.radius_sq {
                damage.0.push(DamageEvent {
                    enemy: *enemy,
                    projectile,
                    damage: 10,
                });
                break;
            }
        }
    }
}

fn apply_damage(
    mut commands: Commands,
    damage: Res<DamageQueue>,
    mut health: Query<&mut Health, With<Enemy>>,
    mut fanout: ResMut<FanoutQueue>,
) {
    for event in &damage.0 {
        commands.entity(event.projectile).despawn();
        let Ok(mut health) = health.get_mut(event.enemy) else {
            continue;
        };
        health.0 -= event.damage;
        fanout.0.push(health.0);
        if health.0 <= 0 {
            commands.entity(event.enemy).despawn();
        }
    }
}

fn combat_fanout(config: Res<CombatConfig>, fanout: Res<FanoutQueue>, mut sink: ResMut<Sink>) {
    for health in &fanout.0 {
        let value = *health as u64;
        for observer in 0..config.observers {
            if ((value ^ observer as u64).wrapping_mul(0x9e37_79b9)) & 7 == 0 {
                sink.0 = sink.0.wrapping_add(value).wrapping_add(observer as u64);
            }
        }
    }
}

fn integrate_dynamic(
    mut query: Query<
        (&mut Position, &mut Velocity, &Acceleration, &Drag, &Bounds),
        With<DynamicBody>,
    >,
) {
    for (mut pos, mut vel, accel, drag, bounds) in &mut query {
        vel.x = (vel.x + accel.x) * drag.0;
        vel.y = (vel.y + accel.y) * drag.0;
        pos.x += vel.x;
        pos.y += vel.y;
        if pos.x < bounds.min || pos.x > bounds.max {
            vel.x = -vel.x * 0.8;
            pos.x = pos.x.clamp(bounds.min, bounds.max);
        }
        if pos.y < bounds.min || pos.y > bounds.max {
            vel.y = -vel.y * 0.8;
            pos.y = pos.y.clamp(bounds.min, bounds.max);
        }
    }
}

fn update_particles(
    mut commands: Commands,
    mut query: Query<(Entity, &mut Position, &Velocity, &mut Lifetime), With<Particle>>,
) {
    for (entity, mut pos, vel, mut lifetime) in &mut query {
        pos.x += vel.x;
        pos.y += vel.y;
        lifetime.0 -= 1;
        if lifetime.0 <= 0 {
            commands.entity(entity).despawn();
        }
    }
}

fn update_orbiters(mut query: Query<(&mut Position, &mut Orbit), With<Orbiter>>) {
    for (mut pos, mut orbit) in &mut query {
        orbit.phase += orbit.speed;
        pos.x = orbit.radius * orbit.phase.cos();
        pos.y = orbit.radius * orbit.phase.sin();
    }
}

fn changed_position_checksum(query: Query<&Position, Changed<Position>>, mut sink: ResMut<Sink>) {
    for pos in &query {
        sink.0 = sink.0.wrapping_add((pos.x.abs() as u64).wrapping_mul(31));
        sink.0 = sink.0.wrapping_add((pos.y.abs() as u64).wrapping_mul(17));
    }
}

fn churn_idle_to_seeking(
    mut commands: Commands,
    frame: Res<ChurnFrame>,
    query: Query<(Entity, &AgentId), (With<Idle>, Without<Dead>)>,
    mut stats: ResMut<ChurnStats>,
) {
    for (entity, id) in &query {
        if (id.0 + frame.0) % 11 == 0 {
            commands
                .entity(entity)
                .remove::<Idle>()
                .insert((Seeking, TargetIndex((id.0 * 17 + frame.0) % 100_000)));
            stats.transitions += 1;
        }
    }
}

fn churn_seeking_to_attacking(
    mut commands: Commands,
    frame: Res<ChurnFrame>,
    query: Query<(Entity, &AgentId), (With<Seeking>, Without<Dead>)>,
    mut stats: ResMut<ChurnStats>,
) {
    for (entity, id) in &query {
        if (id.0 + frame.0) % 3 == 0 {
            commands
                .entity(entity)
                .remove::<Seeking>()
                .insert((Attacking, AttackCooldown(3 + (id.0 % 7) as i32)));
            stats.transitions += 1;
        }
    }
}

fn churn_attack_and_damage(
    mut commands: Commands,
    entities: Res<ChurnEntities>,
    mut attackers: Query<
        (Entity, &AgentId, &TargetIndex, &mut AttackCooldown),
        (With<Attacking>, Without<Dead>),
    >,
    mut victims: Query<&mut Health, Without<Dead>>,
    mut stats: ResMut<ChurnStats>,
) {
    let victim_count = entities.0.len().max(1);
    for (entity, id, target, mut cooldown) in &mut attackers {
        cooldown.0 -= 1;
        if cooldown.0 > 0 {
            continue;
        }

        let victim_index = (target.0 + id.0 * 13) % victim_count;
        if let Ok(mut health) = victims.get_mut(entities.0[victim_index]) {
            health.0 -= 35;
            stats.damage_events += 1;
            stats.checksum = stats
                .checksum
                .wrapping_add((health.0 as u64).wrapping_mul(31).wrapping_add(id.0 as u64));
        }

        if id.0 % 23 == 0 {
            commands
                .entity(entity)
                .remove::<(Attacking, AttackCooldown, TargetIndex)>()
                .insert((Stunned, StunTimer(2 + (id.0 % 5) as i32)));
        } else {
            commands
                .entity(entity)
                .remove::<(Attacking, AttackCooldown, TargetIndex)>()
                .insert(Idle);
        }
        stats.transitions += 1;
    }
}

fn churn_stunned_to_idle(
    mut commands: Commands,
    mut query: Query<(Entity, &mut StunTimer), (With<Stunned>, Without<Dead>)>,
    mut stats: ResMut<ChurnStats>,
) {
    for (entity, mut timer) in &mut query {
        timer.0 -= 1;
        if timer.0 <= 0 {
            commands
                .entity(entity)
                .remove::<(Stunned, StunTimer)>()
                .insert(Idle);
            stats.transitions += 1;
        }
    }
}

fn churn_mark_dead(
    mut commands: Commands,
    query: Query<(Entity, &Health), (Without<Dead>, Or<(With<Idle>, With<Seeking>, With<Attacking>, With<Stunned>)>)>,
    mut stats: ResMut<ChurnStats>,
) {
    for (entity, health) in &query {
        if health.0 <= 0 {
            commands
                .entity(entity)
                .remove::<(Idle, Seeking, Attacking, Stunned, TargetIndex, AttackCooldown, StunTimer)>()
                .insert(Dead);
            stats.transitions += 1;
            stats.deaths += 1;
        }
    }
}

fn churn_checksum(
    query: Query<(&AgentId, &Health), Changed<Health>>,
    mut stats: ResMut<ChurnStats>,
) {
    for (id, health) in &query {
        stats.checksum = stats
            .checksum
            .wrapping_add((id.0 as u64).wrapping_mul(17))
            .wrapping_add(health.0 as u64);
    }
}

fn churn_advance_frame(mut frame: ResMut<ChurnFrame>) {
    frame.0 += 1;
}

// ---- boids: a port of Unity DOTS BoidSystem.cs (EntitiesSamples). The three
// arms of this scenario (zig baseline, bevy_ecs, koru) must produce a
// BIT-IDENTICAL sink, which is the only evidence they do the same arithmetic.
// That makes the ORDER of every float operation below part of the contract:
// f32 throughout, no fast-math, no FMA, no rsqrt approximation, no trig.
//
// Constants are DOTS' own authoring defaults, unscaled.
const BOID_CELL_RADIUS: f32 = 8.0;
const BOID_CELL_COUNT: usize = 32768; // 32*32*32, world [0,256) at radius 8
const BOID_SEP_W: f32 = 1.0;
const BOID_ALIGN_W: f32 = 1.0;
const BOID_TARGET_W: f32 = 2.0;
const BOID_AVERSION: f32 = 30.0;
const BOID_MOVE_SPEED: f32 = 25.0;
const BOID_DT: f32 = 1.0 / 60.0; // DOTS uses min(0.05, dt); fixed here
const BOID_MOVE_DIST: f32 = BOID_MOVE_SPEED * BOID_DT;
const BOID_N_TARGETS: usize = 2;
const BOID_N_OBSTACLES: usize = 1;

fn boid_lengthsq(x: f32, y: f32, z: f32) -> f32 {
    x * x + y * y + z * z
}

// `1.0 / sqrt(len)` and then multiply, NOT `x / sqrt(len)`: the two round
// differently and the cross-arm checksum would diverge.
fn boid_normalizesafe(x: f32, y: f32, z: f32) -> (f32, f32, f32) {
    let len = boid_lengthsq(x, y, z);
    if len > 1.1754944e-38 {
        let inv = 1.0 / len.sqrt();
        (x * inv, y * inv, z * inv)
    } else {
        (0.0, 0.0, 0.0)
    }
}

// `as i64` truncates toward zero, which is the cast the spec asks for.
fn boid_cell_axis(v: f32) -> i64 {
    ((v / BOID_CELL_RADIUS) as i64).clamp(0, 31)
}

// Written as branches rather than f32::clamp so the NaN behaviour matches the
// hand-written baseline arm instead of Rust's clamp contract.
fn boid_clamp_axis(v: f32) -> f32 {
    if v < 0.0 {
        0.0
    } else if v > 255.999 {
        255.999
    } else {
        v
    }
}

// Phase 1. Sawtooth target/obstacle motion plus the unconditional grid clear.
// The motion is integer sawtooth on purpose: libm sin/cos differ in the last
// ulp between toolchains, which would break the oracle.
fn boid_frame_setup(mut flock: ResMut<BoidFlock>, mut cells: ResMut<BoidCells>) {
    let f = flock.frame;
    flock.targets[0] = [((f * 3) % 256) as f32, 128.0, ((f * 5) % 256) as f32];
    flock.targets[1] = [((f * 7) % 256) as f32, 160.0, ((f * 11) % 256) as f32];
    flock.obstacles[0] = [((f * 13) % 256) as f32, 128.0, ((f * 17) % 256) as f32];
    flock.frame = f + 1;

    cells.count.fill(0);
    cells.ax.fill(0.0);
    cells.ay.fill(0.0);
    cells.az.fill(0.0);
    cells.sx.fill(0.0);
    cells.sy.fill(0.0);
    cells.sz.fill(0.0);
    cells.ti.fill(0);
    cells.od.fill(0.0);
}

// Phase 2. Hash and scatter, IN BOID INSERTION ORDER: every boid carries the
// same three components, so they live in one archetype and this query walks
// the table in spawn order. Float addition is not associative, so a different
// visit order is a different checksum.
fn boid_hash_scatter(
    mut boids: Query<(&BoidPosition, &BoidForward, &mut CellIndex)>,
    mut cells: ResMut<BoidCells>,
) {
    for (pos, forward, mut cell) in &mut boids {
        let cx = boid_cell_axis(pos.x);
        let cy = boid_cell_axis(pos.y);
        let cz = boid_cell_axis(pos.z);
        let idx = ((cz * 32 + cy) * 32 + cx) as usize;
        cell.0 = idx;
        cells.count[idx] += 1;
        cells.ax[idx] += forward.x;
        cells.ay[idx] += forward.y;
        cells.az[idx] += forward.z;
        cells.sx[idx] += pos.x;
        cells.sy[idx] += pos.y;
        cells.sz[idx] += pos.z;
    }
}

// Phase 3. DOTS' MergeCells: per CELL, not per boid, and only where count > 0.
//
// Deliberate correction to the sample: DOTS' MergeCells.ExecuteNext writes
// `cellAlignment[i] += cellAlignment[i]`, doubling the accumulator instead of
// adding the member (same for separation). That is a long-standing bug; we sum
// the members, which is what its own surrounding comments say it intends.
fn boid_merge_cells(mut cells: ResMut<BoidCells>, flock: Res<BoidFlock>) {
    for i in 0..BOID_CELL_COUNT {
        let count = cells.count[i];
        if count == 0 {
            continue;
        }
        let n = count as f32;
        let avg = [cells.sx[i] / n, cells.sy[i] / n, cells.sz[i] / n];

        // argmin with ties to the LOWER index: seed on 0 and take a later
        // index only on strict `<`. This is DOTS' NearestPosition.
        let mut nearest_target = 0_i64;
        let mut best = boid_lengthsq(
            flock.targets[0][0] - avg[0],
            flock.targets[0][1] - avg[1],
            flock.targets[0][2] - avg[2],
        );
        for t in 1..BOID_N_TARGETS {
            let d = boid_lengthsq(
                flock.targets[t][0] - avg[0],
                flock.targets[t][1] - avg[1],
                flock.targets[t][2] - avg[2],
            );
            if d < best {
                best = d;
                nearest_target = t as i64;
            }
        }

        let mut nearest_obstacle = boid_lengthsq(
            flock.obstacles[0][0] - avg[0],
            flock.obstacles[0][1] - avg[1],
            flock.obstacles[0][2] - avg[2],
        );
        for o in 1..BOID_N_OBSTACLES {
            let d = boid_lengthsq(
                flock.obstacles[o][0] - avg[0],
                flock.obstacles[o][1] - avg[1],
                flock.obstacles[o][2] - avg[2],
            );
            if d < nearest_obstacle {
                nearest_obstacle = d;
            }
        }

        cells.ti[i] = nearest_target;
        cells.od[i] = nearest_obstacle.sqrt();
    }
}

// Phase 4. Steer, again in boid insertion order.
fn boid_steer(
    mut boids: Query<(&mut BoidPosition, &mut BoidForward, &CellIndex)>,
    cells: Res<BoidCells>,
    flock: Res<BoidFlock>,
) {
    let obstacle = flock.obstacles[0];
    for (mut pos, mut forward, cell) in &mut boids {
        let i = cell.0;
        let n = cells.count[i] as f32;

        let (alignment_x, alignment_y, alignment_z) = boid_normalizesafe(
            cells.ax[i] / n - forward.x,
            cells.ay[i] / n - forward.y,
            cells.az[i] / n - forward.z,
        );
        let alignment = [
            BOID_ALIGN_W * alignment_x,
            BOID_ALIGN_W * alignment_y,
            BOID_ALIGN_W * alignment_z,
        ];

        let (separation_x, separation_y, separation_z) = boid_normalizesafe(
            pos.x * n - cells.sx[i],
            pos.y * n - cells.sy[i],
            pos.z * n - cells.sz[i],
        );
        let separation = [
            BOID_SEP_W * separation_x,
            BOID_SEP_W * separation_y,
            BOID_SEP_W * separation_z,
        ];

        let target = flock.targets[cells.ti[i] as usize];
        let (target_x, target_y, target_z) =
            boid_normalizesafe(target[0] - pos.x, target[1] - pos.y, target[2] - pos.z);
        let target_heading = [
            BOID_TARGET_W * target_x,
            BOID_TARGET_W * target_y,
            BOID_TARGET_W * target_z,
        ];

        let (away_x, away_y, away_z) = boid_normalizesafe(
            pos.x - obstacle[0],
            pos.y - obstacle[1],
            pos.z - obstacle[2],
        );
        let avoid = [
            (obstacle[0] + away_x * BOID_AVERSION) - pos.x,
            (obstacle[1] + away_y * BOID_AVERSION) - pos.y,
            (obstacle[2] + away_z * BOID_AVERSION) - pos.z,
        ];

        let (normal_x, normal_y, normal_z) = boid_normalizesafe(
            alignment[0] + separation[0] + target_heading[0],
            alignment[1] + separation[1] + target_heading[1],
            alignment[2] + separation[2] + target_heading[2],
        );

        let target_forward = if (cells.od[i] - BOID_AVERSION) < 0.0 {
            avoid
        } else {
            [normal_x, normal_y, normal_z]
        };

        let (heading_x, heading_y, heading_z) = boid_normalizesafe(
            forward.x + BOID_DT * (target_forward[0] - forward.x),
            forward.y + BOID_DT * (target_forward[1] - forward.y),
            forward.z + BOID_DT * (target_forward[2] - forward.z),
        );

        forward.x = heading_x;
        forward.y = heading_y;
        forward.z = heading_z;
        pos.x = boid_clamp_axis(pos.x + heading_x * BOID_MOVE_DIST);
        pos.y = boid_clamp_axis(pos.y + heading_y * BOID_MOVE_DIST);
        pos.z = boid_clamp_axis(pos.z + heading_z * BOID_MOVE_DIST);
    }
}

// FULL-CORPUS sink. This used to sum only the first 16 rows in ITERATION
// ORDER, which is not an equivalence oracle: it sampled 0.016% of the work,
// and because bevy's archetype iteration order is not insertion order it did
// not even agree with the zig baseline's first 16. Two references that cannot
// agree with each other cannot arbitrate a third.
//
// Summing every row with a wrapping integer add is ORDER-INDEPENDENT, so it
// holds across implementations that visit rows in different orders. The
// truncation to u64 is deliberate: it tolerates last-bit f32 differences
// between languages while still catching the errors that matter (a row
// missed, the wrong row written, a wrong count).
fn checksum_positions(world: &mut World, active_only: bool) -> u64 {
    let mut sum = 0_u64;
    if active_only {
        let mut query = world.query_filtered::<&Position, With<Active>>();
        for pos in query.iter(world) {
            sum = sum.wrapping_add(pos.x as u64);
        }
    } else {
        let mut query = world.query::<&Position>();
        for pos in query.iter(world) {
            sum = sum.wrapping_add(pos.x as u64);
        }
    }
    sum
}

// LIVE entity count. `world.entities().len()` is allocator CAPACITY, not the
// number of live entities: it returned 131072 (2^17) for a 100k spawn, and
// returned the SAME value after despawning every entity. A sink that cannot
// tell a full world from an empty one validates nothing. Every entity these
// scenarios spawn carries Position, so counting that query is the live count.
fn live_count(world: &mut World) -> u64 {
    let mut query = world.query::<&Position>();
    query.iter(world).count() as u64
}

fn parse_args() -> Config {
    let mut scenario = Scenario::Dense;
    let mut entities = 100_000;
    let mut frames = 100;
    let mut observers = 25;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--scenario" => {
                scenario = match args.next().as_deref() {
                    Some("dense") => Scenario::Dense,
                    Some("sparse") => Scenario::Sparse,
                    Some("fanout") => Scenario::Fanout,
                    Some("spawn") => Scenario::Spawn,
                    Some("spawn_batch") => Scenario::SpawnBatch,
                    Some("despawn") => Scenario::Despawn,
                    Some("add_remove") => Scenario::AddRemove,
                    Some("query_get") => Scenario::QueryGet,
                    Some("schedule_empty") => Scenario::ScheduleEmpty,
                    Some("combat_world") => Scenario::CombatWorld,
                    Some("bevy_strength_world") => Scenario::BevyStrengthWorld,
                    Some("archetype_churn_world") => Scenario::ArchetypeChurnWorld,
                    Some("boids") => Scenario::Boids,
                    other => panic!("unknown scenario: {other:?}"),
                };
            }
            "--entities" => entities = args.next().unwrap().parse().unwrap(),
            "--frames" => frames = args.next().unwrap().parse().unwrap(),
            "--observers" => observers = args.next().unwrap().parse().unwrap(),
            _ => panic!("unknown argument: {arg}"),
        }
    }

    Config {
        scenario,
        entities,
        frames,
        observers,
    }
}

fn build_world(config: &Config) -> World {
    let mut world = World::new();
    let mut entities = Vec::with_capacity(config.entities);

    for i in 0..config.entities {
        let mut entity = world.spawn((Position { x: i as f32, y: 0.0 }, Velocity { x: 1.0, y: -1.0 }, Health(1000)));
        if i % 10 == 0 {
            entity.insert(Active);
        }
        entities.push(entity.id());
    }

    world.insert_resource(EntityList(entities));
    world.insert_resource(Workload {
        frame: 0,
        events_per_frame: config.entities / 10,
        observers: config.observers,
    });
    world.insert_resource(Sink::default());
    world
}

fn build_combat_world(config: &Config) -> World {
    let mut world = World::new();
    let grid_width = 64;
    let cell_size = 16.0;
    let enemy_count = config.entities / 10;
    let projectile_count = config.entities / 10;

    for i in 0..enemy_count {
        let x = ((i * 37) % 1024) as f32 + 0.5;
        let y = ((i * 91) % 1024) as f32 + 0.5;
        world.spawn((Enemy, Position { x, y }, Health(100)));
    }

    for i in 0..projectile_count {
        let x = ((i * 37) % 1024) as f32;
        let y = ((i * 91) % 1024) as f32;
        let vx = if i % 2 == 0 { 0.25 } else { -0.25 };
        let vy = if i % 3 == 0 { 0.15 } else { -0.15 };
        world.spawn((Projectile, Position { x, y }, Velocity { x: vx, y: vy }));
    }

    world.insert_resource(CombatConfig {
        grid_width,
        cell_size,
        radius_sq: 4.0,
        observers: config.observers,
    });
    world.insert_resource(SpatialBuckets(vec![Vec::new(); grid_width * grid_width]));
    world.insert_resource(DamageQueue::default());
    world.insert_resource(FanoutQueue::default());
    world.insert_resource(Sink::default());
    world
}

fn build_bevy_strength_world(config: &Config) -> World {
    let mut world = World::new();
    let dynamic_count = config.entities / 2;
    let particle_count = config.entities / 4;
    let orbiter_count = config.entities - dynamic_count - particle_count;

    for i in 0..dynamic_count {
        world.spawn((
            DynamicBody,
            Position {
                x: (i % 2048) as f32,
                y: ((i * 7) % 2048) as f32,
            },
            Velocity {
                x: ((i % 13) as f32 - 6.0) * 0.01,
                y: ((i % 17) as f32 - 8.0) * 0.01,
            },
            Acceleration {
                x: ((i % 5) as f32 - 2.0) * 0.001,
                y: ((i % 7) as f32 - 3.0) * 0.001,
            },
            Drag(0.999),
            Bounds {
                min: 0.0,
                max: 2048.0,
            },
        ));
    }

    for i in 0..particle_count {
        world.spawn((
            Particle,
            Position {
                x: (i % 1024) as f32,
                y: ((i * 11) % 1024) as f32,
            },
            Velocity {
                x: ((i % 9) as f32 - 4.0) * 0.03,
                y: ((i % 15) as f32 - 7.0) * 0.03,
            },
            Lifetime(1000 + (i % 1000) as i32),
        ));
    }

    for i in 0..orbiter_count {
        world.spawn((
            Orbiter,
            Position { x: 0.0, y: 0.0 },
            Orbit {
                phase: i as f32 * 0.001,
                radius: 10.0 + (i % 100) as f32,
                speed: 0.001 + (i % 11) as f32 * 0.0001,
            },
        ));
    }

    world.insert_resource(Sink::default());
    world
}

fn build_archetype_churn_world(config: &Config) -> World {
    let mut world = World::new();
    let mut entities = Vec::with_capacity(config.entities);
    for i in 0..config.entities {
        let entity = world.spawn((
            AgentId(i),
            Idle,
            Position {
                x: (i % 2048) as f32,
                y: ((i * 7) % 2048) as f32,
            },
            Velocity {
                x: ((i % 13) as f32 - 6.0) * 0.01,
                y: ((i % 17) as f32 - 8.0) * 0.01,
            },
            Health(100 + (i % 200) as i32),
        )).id();
        entities.push(entity);
    }
    world.insert_resource(ChurnFrame::default());
    world.insert_resource(ChurnStats::default());
    world.insert_resource(ChurnEntities(entities));
    world
}

// Boid init is OUTSIDE the timed region in every arm, which is what fixes the
// init-inside-timing asymmetry the README documents for the older rows.
fn build_boid_world(config: &Config) -> World {
    let mut world = World::new();

    for i in 0..config.entities as i64 {
        let (fx, fy, fz) = boid_normalizesafe(
            (i % 13) as f32 - 6.0,
            (i % 17) as f32 - 8.0,
            (i % 7) as f32 - 3.0,
        );
        world.spawn((
            BoidPosition {
                x: (i % 256) as f32,
                y: ((i / 256) % 256) as f32,
                z: ((i / 65536) % 256) as f32,
            },
            BoidForward { x: fx, y: fy, z: fz },
            CellIndex(0),
        ));
    }

    world.insert_resource(BoidCells::default());
    world.insert_resource(BoidFlock::default());
    world
}

fn run_dense(config: &Config) {
    let mut world = build_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems(dense_update);
    // NO WARMUP. This used to run one full frame before the timer started,
    // which (a) gave bevy a pre-faulted, cache-warm world the zig and koru
    // ports never got, and (b) advanced the world one extra frame, so its
    // sink disagreed with theirs by exactly one frame's worth of motion.
    // The full-corpus checksum is what made (b) visible; the 16-row prefix
    // hid it. All three implementations now run exactly `frames` frames.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let sink = checksum_positions(&mut world, false);
    print_result("dense", config, elapsed.as_nanos(), sink);
}

fn run_sparse(config: &Config) {
    let mut world = build_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems(sparse_update);
    // NO WARMUP. This used to run one full frame before the timer started,
    // which (a) gave bevy a pre-faulted, cache-warm world the zig and koru
    // ports never got, and (b) advanced the world one extra frame, so its
    // sink disagreed with theirs by exactly one frame's worth of motion.
    // The full-corpus checksum is what made (b) visible; the 16-row prefix
    // hid it. All three implementations now run exactly `frames` frames.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let sink = checksum_positions(&mut world, true);
    print_result("sparse", config, elapsed.as_nanos(), sink);
}

fn run_fanout(config: &Config) {
    let mut world = build_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems((damage_system, fanout_system).chain());
    // NO WARMUP. This used to run one full frame before the timer started,
    // which (a) gave bevy a pre-faulted, cache-warm world the zig and koru
    // ports never got, and (b) advanced the world one extra frame, so its
    // sink disagreed with theirs by exactly one frame's worth of motion.
    // The full-corpus checksum is what made (b) visible; the 16-row prefix
    // hid it. All three implementations now run exactly `frames` frames.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let sink = world.resource::<Sink>().0;
    print_result("fanout", config, elapsed.as_nanos(), sink);
}

fn run_spawn(config: &Config) {
    let mut world = World::new();
    let start = Instant::now();
    for i in 0..config.entities {
        world.spawn((Position { x: i as f32, y: 0.0 }, Velocity { x: 1.0, y: -1.0 }, Health(1000)));
    }
    let elapsed = start.elapsed();
    print_result("spawn", config, elapsed.as_nanos(), live_count(&mut world));
}

fn run_spawn_batch(config: &Config) {
    let mut world = World::new();
    let bundles = (0..config.entities).map(|i| {
        (
            Position { x: i as f32, y: 0.0 },
            Velocity { x: 1.0, y: -1.0 },
            Health(1000),
        )
    });
    let start = Instant::now();
    world.spawn_batch(bundles);
    let elapsed = start.elapsed();
    print_result("spawn_batch", config, elapsed.as_nanos(), live_count(&mut world));
}

fn run_despawn(config: &Config) {
    let mut world = build_world(config);
    let entities = world.resource::<EntityList>().0.clone();
    let start = Instant::now();
    for entity in entities {
        let _ = world.despawn(entity);
    }
    let elapsed = start.elapsed();
    print_result("despawn", config, elapsed.as_nanos(), live_count(&mut world));
}

fn run_add_remove(config: &Config) {
    let mut world = build_world(config);
    let entities = world.resource::<EntityList>().0.clone();
    let start = Instant::now();
    for entity in &entities {
        world.entity_mut(*entity).insert(Active);
    }
    for entity in &entities {
        world.entity_mut(*entity).remove::<Active>();
    }
    let elapsed = start.elapsed();
    print_result("add_remove", config, elapsed.as_nanos(), entities.len() as u64);
}

fn run_query_get(config: &Config) {
    let mut world = build_world(config);
    let entities = world.resource::<EntityList>().0.clone();
    let mut query = world.query::<&Position>();
    let start = Instant::now();
    let mut sink = 0_u64;
    for _ in 0..config.frames {
        for entity in &entities {
            if let Ok(pos) = query.get(&world, *entity) {
                sink = sink.wrapping_add(pos.x as u64);
            }
        }
    }
    let elapsed = start.elapsed();
    print_result("query_get", config, elapsed.as_nanos(), sink);
}

fn run_schedule_empty(config: &Config) {
    let mut world = World::new();
    world.insert_resource(Sink(0));
    let mut schedule = Schedule::default();
    schedule.add_systems(empty_system);
    // No warmup — see the note on the other scenarios.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    print_result("schedule_empty", config, elapsed.as_nanos(), world.resource::<Sink>().0);
}

fn run_combat_world(config: &Config) {
    let mut world = build_combat_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems((
        clear_combat_queues,
        move_projectiles,
        rebuild_buckets,
        collide_projectiles,
        apply_damage,
        combat_fanout,
    ).chain());
    // NO WARMUP. This used to run one full frame before the timer started,
    // which (a) gave bevy a pre-faulted, cache-warm world the zig and koru
    // ports never got, and (b) advanced the world one extra frame, so its
    // sink disagreed with theirs by exactly one frame's worth of motion.
    // The full-corpus checksum is what made (b) visible; the 16-row prefix
    // hid it. All three implementations now run exactly `frames` frames.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let sink = world.resource::<Sink>().0;
    print_result("combat_world", config, elapsed.as_nanos(), sink);
}

fn run_bevy_strength_world(config: &Config) {
    let mut world = build_bevy_strength_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems((
        integrate_dynamic,
        update_particles,
        update_orbiters,
        changed_position_checksum,
    ));
    schedule.run(&mut world);
    world.resource_mut::<Sink>().0 = 0;

    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let sink = world.resource::<Sink>().0;
    print_result("bevy_strength_world", config, elapsed.as_nanos(), sink);
}

fn run_archetype_churn_world(config: &Config) {
    let mut world = build_archetype_churn_world(config);
    let initial_archetypes = world.archetypes().len();
    let mut schedule = Schedule::default();
    schedule.add_systems((
        churn_idle_to_seeking,
        churn_seeking_to_attacking,
        churn_attack_and_damage,
        churn_stunned_to_idle,
        churn_mark_dead,
        churn_checksum,
        churn_advance_frame,
    ).chain());
    schedule.run(&mut world);
    world.resource_mut::<ChurnStats>().checksum = 0;

    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    let stats = world.resource::<ChurnStats>();
    let sink = stats
        .checksum
        .wrapping_add(stats.transitions.wrapping_mul(3))
        .wrapping_add(stats.damage_events.wrapping_mul(5))
        .wrapping_add(stats.deaths.wrapping_mul(7));
    let final_archetypes = world.archetypes().len();
    println!(
        "{{\"impl\":\"bevy_ecs\",\"scenario\":\"archetype_churn_world\",\"entities\":{},\"frames\":{},\"observers\":{},\"elapsed_ns\":{},\"sink\":{},\"initial_archetypes\":{},\"final_archetypes\":{},\"transitions\":{},\"damage_events\":{},\"deaths\":{}}}",
        config.entities,
        config.frames,
        config.observers,
        elapsed.as_nanos(),
        sink,
        initial_archetypes,
        final_archetypes,
        stats.transitions,
        stats.damage_events,
        stats.deaths
    );
}

fn run_boids(config: &Config) {
    let mut world = build_boid_world(config);
    // The four phases, chained so they run in the spec's order — built once
    // here and re-run per frame, like the other multi-system scenarios. No
    // par_iter anywhere: every arm of this scenario is single-threaded.
    let mut schedule = Schedule::default();
    schedule.add_systems((
        boid_frame_setup,
        boid_hash_scatter,
        boid_merge_cells,
        boid_steer,
    ).chain());
    // No warmup, and no init inside the timer — the frame loop is the whole
    // timed region. See the note on the other scenarios.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();

    // The spec's sink, over boids in spawn order: one archetype, dense table
    // storage, so this query is insertion-ordered. Accumulated in wrapping
    // i64; positions are clamped to [0, 255.999] so it cannot go negative.
    let mut sink = 0_i64;
    let mut query = world.query::<&BoidPosition>();
    for pos in query.iter(&world) {
        let term = (pos.x.abs() as i64) * 31
            + (pos.y.abs() as i64) * 17
            + (pos.z.abs() as i64) * 13;
        sink = sink.wrapping_add(term);
    }
    print_result("boids", config, elapsed.as_nanos(), sink as u64);
}

fn print_result(scenario_name: &str, config: &Config, elapsed_ns: u128, sink: u64) {
    println!(
        "{{\"impl\":\"bevy_ecs\",\"scenario\":\"{}\",\"entities\":{},\"frames\":{},\"observers\":{},\"elapsed_ns\":{},\"sink\":{}}}",
        scenario_name,
        config.entities,
        config.frames,
        config.observers,
        elapsed_ns,
        sink
    );
}

fn main() {
    let config = parse_args();
    match config.scenario {
        Scenario::Dense => run_dense(&config),
        Scenario::Sparse => run_sparse(&config),
        Scenario::Fanout => run_fanout(&config),
        Scenario::Spawn => run_spawn(&config),
        Scenario::SpawnBatch => run_spawn_batch(&config),
        Scenario::Despawn => run_despawn(&config),
        Scenario::AddRemove => run_add_remove(&config),
        Scenario::QueryGet => run_query_get(&config),
        Scenario::ScheduleEmpty => run_schedule_empty(&config),
        Scenario::CombatWorld => run_combat_world(&config),
        Scenario::BevyStrengthWorld => run_bevy_strength_world(&config),
        Scenario::ArchetypeChurnWorld => run_archetype_churn_world(&config),
        Scenario::Boids => run_boids(&config),
    }
}
