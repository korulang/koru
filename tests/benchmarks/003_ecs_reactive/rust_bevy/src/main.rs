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

fn empty_system() {}

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

fn checksum_positions(world: &mut World, active_only: bool) -> u64 {
    let mut sum = 0_u64;
    if active_only {
        let mut query = world.query_filtered::<&Position, With<Active>>();
        for pos in query.iter(world).take(16) {
            sum = sum.wrapping_add(pos.x as u64);
        }
    } else {
        let mut query = world.query::<&Position>();
        for pos in query.iter(world).take(16) {
            sum = sum.wrapping_add(pos.x as u64);
        }
    }
    sum
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

fn run_dense(config: &Config) {
    let mut world = build_world(config);
    let mut schedule = Schedule::default();
    schedule.add_systems(dense_update);
    schedule.run(&mut world);

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
    schedule.run(&mut world);

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
    schedule.run(&mut world);

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
    print_result("spawn", config, elapsed.as_nanos(), world.entities().len() as u64);
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
    print_result("spawn_batch", config, elapsed.as_nanos(), world.entities().len() as u64);
}

fn run_despawn(config: &Config) {
    let mut world = build_world(config);
    let entities = world.resource::<EntityList>().0.clone();
    let start = Instant::now();
    for entity in entities {
        let _ = world.despawn(entity);
    }
    let elapsed = start.elapsed();
    print_result("despawn", config, elapsed.as_nanos(), world.entities().len() as u64);
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
    let mut schedule = Schedule::default();
    schedule.add_systems(empty_system);
    schedule.run(&mut world);
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.run(&mut world);
    }
    let elapsed = start.elapsed();
    print_result("schedule_empty", config, elapsed.as_nanos(), 0);
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
    schedule.run(&mut world);

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
    }
}
