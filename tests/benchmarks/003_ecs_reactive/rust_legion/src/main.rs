//! The legion arm of the `003_ecs_reactive` ECS surface benchmark.
//!
//! Only the `boids` scenario is implemented — a port of Unity DOTS
//! `BoidSystem.cs` (EntitiesSamples). Every arm of this scenario must produce a
//! BIT-IDENTICAL `sink`, which is the only evidence they do the same
//! arithmetic. That makes the ORDER of every float operation below part of the
//! contract: f32 throughout, no fast-math, no FMA, no rsqrt approximation, no
//! trigonometry. Any other `--scenario` refuses on stderr and emits no line, so
//! an absent row means "not ported", never "ran and produced nothing".
//!
//! Single-threaded: legion's `parallel` feature is off in Cargo.toml, so
//! `Schedule::execute` runs the four systems sequentially on this thread with no
//! rayon anywhere. No `par_for_each`.

use legion::{system, IntoQuery, Resources, Schedule, World};
use std::ops::{Add, Mul, Sub};
use std::time::Instant;

// ---------------------------------------------------------------------------
// Constants — DOTS' own authoring defaults, unscaled.
// ---------------------------------------------------------------------------

const CELL_RADIUS: f32 = 8.0;
const CELL_COUNT: usize = 32768; // 32*32*32, world [0,256) at radius 8
const SEP_W: f32 = 1.0;
const ALIGN_W: f32 = 1.0;
const TARGET_W: f32 = 2.0;
const AVERSION: f32 = 30.0;
const MOVE_SPEED: f32 = 25.0;
const DT: f32 = 1.0 / 60.0; // DOTS uses min(0.05, dt); fixed here
const MOVE_DIST: f32 = MOVE_SPEED * DT;
const N_TARGETS: usize = 2;
const N_OBSTACLES: usize = 1;

// ---------------------------------------------------------------------------
// Vec3 — the shared arithmetic. Componentwise and nothing else, so the operator
// forms below expand to exactly the scalar operations the spec lists.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Vec3 {
    x: f32,
    y: f32,
    z: f32,
}

impl Vec3 {
    const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };

    #[inline]
    const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    #[inline]
    fn lengthsq(self) -> f32 {
        self.x * self.x + self.y * self.y + self.z * self.z
    }

    /// `1.0 / sqrt(len)` and THEN multiply, not `x / sqrt(len)`: the two round
    /// differently and the cross-arm checksum would diverge.
    #[inline]
    fn normalizesafe(self) -> Self {
        let len = self.lengthsq();
        if len > 1.1754944e-38 {
            let inv = 1.0 / len.sqrt();
            Self::new(self.x * inv, self.y * inv, self.z * inv)
        } else {
            Self::ZERO
        }
    }
}

impl Add for Vec3 {
    type Output = Self;
    #[inline]
    fn add(self, o: Self) -> Self {
        Self::new(self.x + o.x, self.y + o.y, self.z + o.z)
    }
}

impl Sub for Vec3 {
    type Output = Self;
    #[inline]
    fn sub(self, o: Self) -> Self {
        Self::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
}

impl Mul<f32> for Vec3 {
    type Output = Self;
    #[inline]
    fn mul(self, s: f32) -> Self {
        Self::new(self.x * s, self.y * s, self.z * s)
    }
}

/// `as i64` truncates toward zero, which is the cast the spec asks for.
#[inline]
fn cell_axis(v: f32) -> i64 {
    ((v / CELL_RADIUS) as i64).clamp(0, 31)
}

/// Branches rather than `f32::clamp` so the NaN behaviour matches the
/// hand-written baseline arm instead of Rust's clamp contract.
#[inline]
fn clamp_axis(v: f32) -> f32 {
    if v < 0.0 {
        0.0
    } else if v > 255.999 {
        255.999
    } else {
        v
    }
}

// ---------------------------------------------------------------------------
// Components. legion's own benchmarks declare components as newtypes over a
// vector type (`struct Position(Vector3<f32>)`), and that is the shape chosen
// here: one 12-byte stream for position, one for forward, one 4-byte stream for
// the hashed cell. Three archetype columns, not seven scalar ones — this is the
// packing legion is supposed to be good at, and the reason this arm exists.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
struct Position(Vec3);

#[derive(Clone, Copy, Debug, PartialEq)]
struct Forward(Vec3);

/// The cell a boid hashed into in phase 2, reused verbatim in phase 4: the
/// position has not moved in between, so rehashing would only risk drifting
/// from the other arms.
#[derive(Clone, Copy, Debug, PartialEq)]
struct CellIndex(u32);

// ---------------------------------------------------------------------------
// Resources.
//
// The 32^3 grid is DENSE and bounded, not per-entity data, so it is a resource
// and not a component: there is exactly one of it and it is indexed by a
// computed integer, which is the opposite of an archetype column. DOTS hashes
// `int3(floor(pos/cellRadius))` into an unbounded NativeParallelMultiHashMap and
// reallocates it per frame; we clamp into a fixed grid and clear it, which is
// why phase 1 exists at all.
//
// ARRAY-OF-STRUCTS by default. Every random touch of the grid — the scatter in
// phase 2 and the gather in phase 4 — reads or writes many fields of ONE cell,
// so AoS turns nine strided array accesses into one cache line and one bounds
// check. Struct-of-arrays would win phase 1 (nine `fill`s, most of them a
// memset) and the phase 3 skip test (a dense count array over a grid that is
// >95% empty at these entity counts), which is why the `soa_grid` feature keeps
// it measurable instead of assumed.
//
// Both layouts expose the same tiny API and the arithmetic lives in the phase
// functions ONLY, so the two cannot disagree on the checksum.
// ---------------------------------------------------------------------------

/// One resolved grid cell, as the steer phase wants to see it.
#[derive(Clone, Copy, Debug, Default)]
struct Cell {
    count: i64,
    /// heading sum
    a: Vec3,
    /// position sum
    s: Vec3,
    /// nearest-target index
    ti: i64,
    /// nearest-obstacle distance
    od: f32,
}

// Only the array-of-structs grid stores whole `Cell`s; the struct-of-arrays one
// assembles them on read, so it never needs a zero value.
#[cfg(not(feature = "soa_grid"))]
impl Cell {
    const EMPTY: Self = Self {
        count: 0,
        a: Vec3::ZERO,
        s: Vec3::ZERO,
        ti: 0,
        od: 0.0,
    };
}

#[cfg(not(feature = "soa_grid"))]
struct Grid {
    cells: Vec<Cell>,
}

#[cfg(not(feature = "soa_grid"))]
impl Grid {
    fn new() -> Self {
        Self {
            cells: vec![Cell::EMPTY; CELL_COUNT],
        }
    }

    #[inline]
    fn clear(&mut self) {
        self.cells.fill(Cell::EMPTY);
    }

    #[inline]
    fn accumulate(&mut self, idx: usize, pos: Vec3, fwd: Vec3) {
        let c = &mut self.cells[idx];
        c.count += 1;
        c.a.x += fwd.x;
        c.a.y += fwd.y;
        c.a.z += fwd.z;
        c.s.x += pos.x;
        c.s.y += pos.y;
        c.s.z += pos.z;
    }

    #[inline]
    fn count(&self, idx: usize) -> i64 {
        self.cells[idx].count
    }

    #[inline]
    fn sum_pos(&self, idx: usize) -> Vec3 {
        self.cells[idx].s
    }

    #[inline]
    fn set_resolved(&mut self, idx: usize, ti: i64, od: f32) {
        let c = &mut self.cells[idx];
        c.ti = ti;
        c.od = od;
    }

    #[inline]
    fn cell(&self, idx: usize) -> Cell {
        self.cells[idx]
    }
}

#[cfg(feature = "soa_grid")]
struct Grid {
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

#[cfg(feature = "soa_grid")]
impl Grid {
    fn new() -> Self {
        Self {
            count: vec![0; CELL_COUNT],
            ax: vec![0.0; CELL_COUNT],
            ay: vec![0.0; CELL_COUNT],
            az: vec![0.0; CELL_COUNT],
            sx: vec![0.0; CELL_COUNT],
            sy: vec![0.0; CELL_COUNT],
            sz: vec![0.0; CELL_COUNT],
            ti: vec![0; CELL_COUNT],
            od: vec![0.0; CELL_COUNT],
        }
    }

    #[inline]
    fn clear(&mut self) {
        self.count.fill(0);
        self.ax.fill(0.0);
        self.ay.fill(0.0);
        self.az.fill(0.0);
        self.sx.fill(0.0);
        self.sy.fill(0.0);
        self.sz.fill(0.0);
        self.ti.fill(0);
        self.od.fill(0.0);
    }

    #[inline]
    fn accumulate(&mut self, idx: usize, pos: Vec3, fwd: Vec3) {
        self.count[idx] += 1;
        self.ax[idx] += fwd.x;
        self.ay[idx] += fwd.y;
        self.az[idx] += fwd.z;
        self.sx[idx] += pos.x;
        self.sy[idx] += pos.y;
        self.sz[idx] += pos.z;
    }

    #[inline]
    fn count(&self, idx: usize) -> i64 {
        self.count[idx]
    }

    #[inline]
    fn sum_pos(&self, idx: usize) -> Vec3 {
        Vec3::new(self.sx[idx], self.sy[idx], self.sz[idx])
    }

    #[inline]
    fn set_resolved(&mut self, idx: usize, ti: i64, od: f32) {
        self.ti[idx] = ti;
        self.od[idx] = od;
    }

    #[inline]
    fn cell(&self, idx: usize) -> Cell {
        Cell {
            count: self.count[idx],
            a: Vec3::new(self.ax[idx], self.ay[idx], self.az[idx]),
            s: Vec3::new(self.sx[idx], self.sy[idx], self.sz[idx]),
            ti: self.ti[idx],
            od: self.od[idx],
        }
    }
}

/// Targets, obstacle and the frame counter. One of each, not per-entity, so a
/// resource for the same reason the grid is one.
#[derive(Default)]
struct Flock {
    frame: i64,
    targets: [Vec3; N_TARGETS],
    obstacles: [Vec3; N_OBSTACLES],
}

// ---------------------------------------------------------------------------
// The frame — four phases, in the spec's order.
// ---------------------------------------------------------------------------

/// Phase 1. Sawtooth target/obstacle motion plus the unconditional grid clear.
/// The motion is integer sawtooth on purpose: libm sin/cos differ in the last
/// ulp between toolchains, which would break the oracle.
#[system]
fn frame_setup(#[resource] flock: &mut Flock, #[resource] grid: &mut Grid) {
    let f = flock.frame;
    flock.targets[0] = Vec3::new(((f * 3) % 256) as f32, 128.0, ((f * 5) % 256) as f32);
    flock.targets[1] = Vec3::new(((f * 7) % 256) as f32, 160.0, ((f * 11) % 256) as f32);
    flock.obstacles[0] = Vec3::new(((f * 13) % 256) as f32, 128.0, ((f * 17) % 256) as f32);
    flock.frame = f + 1;

    grid.clear();
}

/// Phase 2. Hash and scatter, IN BOID INSERTION ORDER. Every boid carries the
/// same three components, so they all live in one archetype, and legion's
/// `for_each_mut` (which is what `#[system(for_each)]` expands to — the
/// sequential one, never `par_for_each_mut`) walks that archetype's columns
/// front to back. Float addition is not associative, so a different visit order
/// is a different checksum. `query_iteration_is_insertion_order` and
/// `for_each_mut_is_insertion_order` below pin this down.
#[system(for_each)]
fn hash_scatter(
    pos: &Position,
    fwd: &Forward,
    cell: &mut CellIndex,
    #[resource] grid: &mut Grid,
) {
    let cx = cell_axis(pos.0.x);
    let cy = cell_axis(pos.0.y);
    let cz = cell_axis(pos.0.z);
    let idx = ((cz * 32 + cy) * 32 + cx) as usize;
    cell.0 = idx as u32;
    grid.accumulate(idx, pos.0, fwd.0);
}

/// Phase 3. DOTS' `MergeCells`: per CELL, not per boid, and only where
/// `count > 0`.
///
/// Deliberate correction to the sample: DOTS' `MergeCells.ExecuteNext` writes
/// `cellAlignment[i] += cellAlignment[i]`, doubling the accumulator instead of
/// adding the member (same for separation). That is a long-standing bug; we sum
/// the members, which is what its own surrounding comments say it intends.
#[system]
fn merge_cells(#[resource] grid: &mut Grid, #[resource] flock: &Flock) {
    for idx in 0..CELL_COUNT {
        let count = grid.count(idx);
        if count == 0 {
            continue;
        }
        let n = count as f32;
        let s = grid.sum_pos(idx);
        let avg = Vec3::new(s.x / n, s.y / n, s.z / n);

        // argmin with ties to the LOWER index: seed on 0 and take a later index
        // only on strict `<`. This is DOTS' NearestPosition.
        let mut nearest_target = 0_i64;
        let mut best = (flock.targets[0] - avg).lengthsq();
        for t in 1..N_TARGETS {
            let d = (flock.targets[t] - avg).lengthsq();
            if d < best {
                best = d;
                nearest_target = t as i64;
            }
        }

        let mut nearest_obstacle = (flock.obstacles[0] - avg).lengthsq();
        for o in 1..N_OBSTACLES {
            let d = (flock.obstacles[o] - avg).lengthsq();
            if d < nearest_obstacle {
                nearest_obstacle = d;
            }
        }

        grid.set_resolved(idx, nearest_target, nearest_obstacle.sqrt());
    }
}

/// Phase 4. Steer, again in boid insertion order.
#[system(for_each)]
fn steer(
    pos: &mut Position,
    fwd: &mut Forward,
    cell: &CellIndex,
    #[resource] grid: &Grid,
    #[resource] flock: &Flock,
) {
    let c = grid.cell(cell.0 as usize);
    let n = c.count as f32;
    let position = pos.0;
    let forward = fwd.0;
    let obstacle = flock.obstacles[0];

    let alignment = Vec3::new(
        c.a.x / n - forward.x,
        c.a.y / n - forward.y,
        c.a.z / n - forward.z,
    )
    .normalizesafe()
        * ALIGN_W;

    let separation = (position * n - c.s).normalizesafe() * SEP_W;

    let target_heading = (flock.targets[c.ti as usize] - position).normalizesafe() * TARGET_W;

    let obstacle_steering = position - obstacle;
    let avoid = (obstacle + obstacle_steering.normalizesafe() * AVERSION) - position;

    let normal_heading = (alignment + separation + target_heading).normalizesafe();

    let target_forward = if (c.od - AVERSION) < 0.0 {
        avoid
    } else {
        normal_heading
    };

    let next_heading = (forward + (target_forward - forward) * DT).normalizesafe();

    fwd.0 = next_heading;
    pos.0 = Vec3::new(
        clamp_axis(position.x + next_heading.x * MOVE_DIST),
        clamp_axis(position.y + next_heading.y * MOVE_DIST),
        clamp_axis(position.z + next_heading.z * MOVE_DIST),
    );
}

// ---------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------

struct Config {
    entities: usize,
    frames: usize,
    observers: usize,
}

fn parse_args() -> (Option<String>, Config) {
    let mut scenario = None;
    let mut entities = 100_000;
    let mut frames = 100;
    let mut observers = 25;
    let mut args = std::env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--scenario" => scenario = args.next(),
            "--entities" => entities = args.next().unwrap().parse().unwrap(),
            "--frames" => frames = args.next().unwrap().parse().unwrap(),
            "--observers" => observers = args.next().unwrap().parse().unwrap(),
            _ => panic!("unknown argument: {arg}"),
        }
    }

    (
        scenario,
        Config {
            entities,
            frames,
            observers,
        },
    )
}

/// Boid init is OUTSIDE the timed region in every arm, which is what fixes the
/// init-inside-timing asymmetry the README documents for the older rows.
/// `extend` inserts the whole batch into a single archetype in argument order.
fn build_boid_world(entities: usize) -> World {
    let mut world = World::default();
    let mut batch = Vec::with_capacity(entities);

    for i in 0..entities as i64 {
        let fwd = Vec3::new(
            (i % 13) as f32 - 6.0,
            (i % 17) as f32 - 8.0,
            (i % 7) as f32 - 3.0,
        )
        .normalizesafe();
        batch.push((
            Position(Vec3::new(
                (i % 256) as f32,
                ((i / 256) % 256) as f32,
                ((i / 65536) % 256) as f32,
            )),
            Forward(fwd),
            CellIndex(0),
        ));
    }

    world.extend(batch);
    world
}

fn run_boids(config: &Config) {
    let mut world = build_boid_world(config.entities);

    let mut resources = Resources::default();
    resources.insert(Grid::new());
    resources.insert(Flock::default());

    // Built once, outside the timed region, and re-run per frame. With the
    // `parallel` feature off this is a straight in-order walk of the four
    // systems on this thread.
    let mut schedule = Schedule::builder()
        .add_system(frame_setup_system())
        .add_system(hash_scatter_system())
        .add_system(merge_cells_system())
        .add_system(steer_system())
        .build();

    // No warmup, and no init inside the timer — the frame loop is the whole
    // timed region.
    let start = Instant::now();
    for _ in 0..config.frames {
        schedule.execute(&mut world, &mut resources);
    }
    let elapsed = start.elapsed();

    // The spec's sink, over boids in insertion order. Accumulated in wrapping
    // i64; positions are clamped to [0, 255.999] so it cannot go negative.
    let mut sink = 0_i64;
    let mut query = <&Position>::query();
    for pos in query.iter(&world) {
        let term = (pos.0.x.abs() as i64) * 31
            + (pos.0.y.abs() as i64) * 17
            + (pos.0.z.abs() as i64) * 13;
        sink = sink.wrapping_add(term);
    }

    println!(
        "{{\"impl\":\"legion\",\"scenario\":\"boids\",\"entities\":{},\"frames\":{},\"observers\":{},\"elapsed_ns\":{},\"sink\":{}}}",
        config.entities,
        config.frames,
        config.observers,
        elapsed.as_nanos(),
        sink as u64
    );
}

fn main() {
    let (scenario, config) = parse_args();
    match scenario.as_deref() {
        Some("boids") => run_boids(&config),
        // Same convention as the koru arm: a scenario this arm has not ported
        // refuses on stderr and emits no line, so an absent row in
        // results.jsonl means "not implemented", never "ran and produced
        // nothing".
        _ => eprintln!("legion: unknown or unimplemented --scenario"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The read-only path used by the sink.
    #[test]
    fn query_iteration_is_insertion_order() {
        const N: usize = 5000;
        let world = build_boid_world(N);
        let mut query = <&Position>::query();
        let mut seen = 0_usize;
        for (i, pos) in query.iter(&world).enumerate() {
            let i = i as i64;
            assert_eq!(
                pos.0,
                Vec3::new(
                    (i % 256) as f32,
                    ((i / 256) % 256) as f32,
                    ((i / 65536) % 256) as f32
                ),
                "row {i} out of insertion order"
            );
            seen += 1;
        }
        assert_eq!(seen, N);
    }

    /// The MUTABLE path phases 2 and 4 actually run on: `#[system(for_each)]`
    /// expands to `Query::for_each_mut`. Stamps a visit counter into CellIndex
    /// and asserts it lands in insertion order, which is the property the
    /// non-associative float accumulation in phase 2 depends on.
    #[test]
    fn for_each_mut_is_insertion_order() {
        const N: usize = 5000;
        let mut world = build_boid_world(N);
        let mut query = <(&Position, &mut CellIndex)>::query();
        let mut visit = 0_u32;
        query.for_each_mut(&mut world, |(_, cell)| {
            cell.0 = visit;
            visit += 1;
        });
        assert_eq!(visit, N as u32);

        let mut check = <(&Position, &CellIndex)>::query();
        for (pos, cell) in check.iter(&world) {
            let i = cell.0 as i64;
            assert_eq!(
                pos.0.x,
                (i % 256) as f32,
                "for_each_mut visited row {i} out of order"
            );
        }
    }

    /// Every boid carries the same three components, so there must be exactly
    /// one archetype: that is what makes "archetype order" and "insertion
    /// order" the same thing here. `iter_chunks` yields one chunk per matching
    /// archetype, so counting chunks counts archetypes.
    #[test]
    fn boids_live_in_one_archetype() {
        let world = build_boid_world(5000);
        let mut query = <(&Position, &Forward, &CellIndex)>::query();
        assert_eq!(query.iter_chunks(&world).count(), 1);
    }
}
