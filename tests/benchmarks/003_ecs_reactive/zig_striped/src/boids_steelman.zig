// An adversarial, hand-optimised Zig implementation of the `boids` scenario.
//
// Purpose: before anyone claims Koru beats hand-written Zig on this workload,
// someone has to try honestly to beat Koru in Zig. This file is that attempt.
// It computes EXACTLY what `main.zig`'s `boids` computes -- same operation
// order, same f32 rounding, same `sink` -- and is optimised as hard as it can
// be without touching the arithmetic.
//
// NOT done, because it would change the arithmetic:
//   * no `@setFloatMode(.optimized)`; fast-math reassociates and the checksum
//     is the only oracle we have
//   * no `frsqrte` / rsqrt approximation; the contract says `1.0 / @sqrt(len)`
//   * no reassociation of the scatter accumulation; f32 add is not
//     associative, so `run_scatter` below seeds its register accumulator FROM
//     MEMORY and preserves the exact left-to-right association
//   * `avoid` is not simplified to `(pos - ob) * (aversion/d - 1)` even though
//     that is algebraically the same vector -- it rounds differently
//
// Every optimisation that IS applied is annotated where it appears, with its
// measured delta. The two that matter most, in order:
//
//   1. Module-level fixed-size arrays AND a loop body with no runtime-indexed
//      alloca in it. Measured as a 2x2 on a verbatim extraction of the
//      baseline: on heap slices nothing vectorises no matter what the body
//      looks like (221ms / 227ms); on static globals with the baseline's
//      `targets[@intCast(cell_target[idx])]` still nothing (220ms); on static
//      globals with that replaced by a two-way scalar select, LLVM widens the
//      whole steer loop to 4 lanes and it drops to 114ms. NEITHER condition
//      does anything alone. That pair is the entire difference between the
//      `zig_striped` baseline and everything below.
//
//   2. Per-cell hoisting. `cells[idx].a / n`, `f32(count)`, the target choice
//      and the `(od - AVERSION) < 0` predicate are functions of the CELL, not
//      the boid. Computing them once per occupied cell (~950 of them,
//      measured) instead of once per boid (100k) is loop-invariant code motion
//      that LLVM cannot do through a gather. Bit-identical by construction.
//
// Phase 1 still clears all 32768 cells unconditionally, including `ti` and
// `od`, whose cleared values are provably never read. That is contract shape;
// skipping it would be measuring a different program.

const std = @import("std");

// ------------------------------------------------------------------ knobs
// Comptime-only. The shipped configuration is the fastest measured one; the
// flags exist so the ablation table in the report is reproducible.
const steer_w: usize = 16; // 1 == scalar steer. 16 measured best; 12 is 2.3x
// worse than 16, because a non-power-of-two vector legalises badly.
const hash_w: usize = 8; // 1 == scalar cell-index pass
const fuse_hash_scatter: bool = false; // true == one pass, like `main.zig`
const run_scatter: bool = false; // measured a 6ms LOSS -- see scatterPass
const hoist_cell: bool = true;
const track_occupied: bool = false; // measured a 3ms net LOSS -- see scatterPass
const skip_dead_arm: bool = true;
const aos_cells: bool = true;
const range_scan: bool = true;
// Per-phase nanosecond breakdown on stderr, mirroring `main.zig`'s
// `boids_phase` twin. Comptime-off by default, so the shipped binary has no
// clock anywhere in the frame loop.
const phase_timing: bool = false;

// -------------------------------------------------------------- constants
// DOTS' own authoring defaults, unscaled. Same values as `main.zig`.
const cell_radius: f32 = 8.0;
const axis_cells: i32 = 32;
const cell_total: usize = 32 * 32 * 32;
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
const flt_min_normal: f32 = 1.1754944e-38;

const max_entities: usize = 1 << 20;

// ---------------------------------------------------------------- storage
// Fixed-size module-level arrays: statically known addresses, and distinct
// globals cannot alias each other.
var store_px: [max_entities]f32 align(64) = undefined;
var store_py: [max_entities]f32 align(64) = undefined;
var store_pz: [max_entities]f32 align(64) = undefined;
var store_fx: [max_entities]f32 align(64) = undefined;
var store_fy: [max_entities]f32 align(64) = undefined;
var store_fz: [max_entities]f32 align(64) = undefined;
var store_cell: [max_entities]u32 align(64) = undefined;

// The scatter accumulator, packed one cell per 32-byte record.
//
// Lanes: 0..2 alignment sum, 3..5 position sum, 6 count, 7 unused. The count
// rides along as f32: every value it takes is a non-negative integer below
// 2^24, so `+ 1.0` is exact and this holds the same bit pattern
// `@floatFromInt(count)` would produce. Packing turns the scatter's seven
// scattered read-modify-writes into one 32-byte one.
const CellV = @Vector(8, f32);
var store_acc: [cell_total]CellV align(64) = [_]CellV{@splat(@as(f32, 0))} ** cell_total;

// The same state spread across separate columns, for the `aos_cells == false`
// ablation.
var store_count: [cell_total]i32 align(64) = [_]i32{0} ** cell_total;
var store_ax: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;
var store_ay: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;
var store_az: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;
var store_sx: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;
var store_sy: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;
var store_sz: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;

// Contract cell state written in phase 3. Kept and cleared because the
// contract lists it.
var store_ti: [cell_total]i32 align(64) = [_]i32{0} ** cell_total;
var store_od: [cell_total]f32 align(64) = [_]f32{0} ** cell_total;

// Per-cell steer inputs, derived in phase 3. Never read for an empty cell, so
// they need no clearing.
var store_anx: [cell_total]f32 align(64) = undefined;
var store_any: [cell_total]f32 align(64) = undefined;
var store_anz: [cell_total]f32 align(64) = undefined;
var store_nf: [cell_total]f32 align(64) = undefined;
var store_hsx: [cell_total]f32 align(64) = undefined;
var store_hsy: [cell_total]f32 align(64) = undefined;
var store_hsz: [cell_total]f32 align(64) = undefined;
var store_flags: [cell_total]i32 align(64) = undefined;

// Cells touched this frame, in first-touch order.
var store_occ: [cell_total]u32 align(64) = undefined;

// Comptime-constant pointers to the globals above. `arr[i]` on a global array
// makes Zig copy the WHOLE array to the stack first -- verified, a 4 MiB
// memcpy in the function prologue, which overflows the main thread stack
// outright at these sizes. `ptr[i]` does not, and the pointer folds to the
// global's static address, so the aliasing and addressing properties that
// matter here are unchanged.
const bpx: *[max_entities]f32 = &store_px;
const bpy: *[max_entities]f32 = &store_py;
const bpz: *[max_entities]f32 = &store_pz;
const bfx: *[max_entities]f32 = &store_fx;
const bfy: *[max_entities]f32 = &store_fy;
const bfz: *[max_entities]f32 = &store_fz;
const bcell: *[max_entities]u32 = &store_cell;

const cacc: *[cell_total]CellV = &store_acc;
const ccount: *[cell_total]i32 = &store_count;
const cax: *[cell_total]f32 = &store_ax;
const cay: *[cell_total]f32 = &store_ay;
const caz: *[cell_total]f32 = &store_az;
const csx: *[cell_total]f32 = &store_sx;
const csy: *[cell_total]f32 = &store_sy;
const csz: *[cell_total]f32 = &store_sz;
const cti: *[cell_total]i32 = &store_ti;
const cod: *[cell_total]f32 = &store_od;

const hanx: *[cell_total]f32 = &store_anx;
const hany: *[cell_total]f32 = &store_any;
const hanz: *[cell_total]f32 = &store_anz;
const hnf: *[cell_total]f32 = &store_nf;
const hsx: *[cell_total]f32 = &store_hsx;
const hsy: *[cell_total]f32 = &store_hsy;
const hsz: *[cell_total]f32 = &store_hsz;
const hflags: *[cell_total]i32 = &store_flags;

const occ: *[cell_total]u32 = &store_occ;

var occ_len: usize = 0;
var scan_lo: u32 = 0;
var scan_hi: u32 = cell_total - 1;
var n_ent: usize = 0;

// ----------------------------------------------------------------- helpers
inline fn lengthsq(x: f32, y: f32, z: f32) f32 {
    return x * x + y * y + z * z;
}

const Vec3 = struct { x: f32, y: f32, z: f32 };

// `1.0 / sqrt(len)` and then multiply -- NOT `x / sqrt(len)`.
inline fn normalizesafe(x: f32, y: f32, z: f32) Vec3 {
    const len = lengthsq(x, y, z);
    if (len > flt_min_normal) {
        const inv = 1.0 / @sqrt(len);
        return .{ .x = x * inv, .y = y * inv, .z = z * inv };
    }
    return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
}

fn VecOf(comptime w: usize) type {
    return @Vector(w, f32);
}

// Vector form of `normalizesafe`. `inv` is computed unconditionally; lanes
// where `len <= flt_min_normal` can produce inf or NaN but are selected away,
// so every surviving lane is bit-identical to the scalar form.
inline fn normalizesafeV(comptime w: usize, x: VecOf(w), y: VecOf(w), z: VecOf(w)) [3]VecOf(w) {
    const V = VecOf(w);
    const len = x * x + y * y + z * z;
    const inv = @as(V, @splat(@as(f32, 1.0))) / @sqrt(len);
    const ok = len > @as(V, @splat(flt_min_normal));
    const zero: V = @splat(@as(f32, 0.0));
    return .{
        @select(f32, ok, x * inv, zero),
        @select(f32, ok, y * inv, zero),
        @select(f32, ok, z * inv, zero),
    };
}

const Frame = struct {
    t0x: f32,
    t0y: f32,
    t0z: f32,
    t1x: f32,
    t1y: f32,
    t1z: f32,
    obx: f32,
    oby: f32,
    obz: f32,
};

// ------------------------------------------------ cell accumulator access
const Acc = struct { nf: f32, ax: f32, ay: f32, az: f32, sx: f32, sy: f32, sz: f32 };

inline fn accClear() void {
    if (aos_cells) {
        @memset(cacc, @splat(@as(f32, 0)));
    } else {
        @memset(ccount, 0);
        @memset(cax, 0);
        @memset(cay, 0);
        @memset(caz, 0);
        @memset(csx, 0);
        @memset(csy, 0);
        @memset(csz, 0);
    }
}

inline fn accAdd(c: usize, fx: f32, fy: f32, fz: f32, px: f32, py: f32, pz: f32) void {
    if (aos_cells) {
        cacc[c] += CellV{ fx, fy, fz, px, py, pz, 1.0, 0.0 };
    } else {
        cax[c] += fx;
        cay[c] += fy;
        caz[c] += fz;
        csx[c] += px;
        csy[c] += py;
        csz[c] += pz;
        ccount[c] += 1;
    }
}

inline fn accRead(c: usize) Acc {
    if (aos_cells) {
        const v = cacc[c];
        return .{ .nf = v[6], .ax = v[0], .ay = v[1], .az = v[2], .sx = v[3], .sy = v[4], .sz = v[5] };
    } else {
        return .{
            .nf = @floatFromInt(ccount[c]),
            .ax = cax[c],
            .ay = cay[c],
            .az = caz[c],
            .sx = csx[c],
            .sy = csy[c],
            .sz = csz[c],
        };
    }
}

inline fn accEmpty(c: usize) bool {
    return if (aos_cells) cacc[c][6] == 0.0 else ccount[c] == 0;
}

// Everything phase 4 needs about a cell, however it is stored.
const CellIn = struct {
    anx: f32,
    any: f32,
    anz: f32,
    nf: f32,
    sx: f32,
    sy: f32,
    sz: f32,
    use_t1: bool,
    avoiding: bool,
};

inline fn cellInputs(c: usize) CellIn {
    if (hoist_cell) {
        const fl = hflags[c];
        return .{
            .anx = hanx[c],
            .any = hany[c],
            .anz = hanz[c],
            .nf = hnf[c],
            .sx = hsx[c],
            .sy = hsy[c],
            .sz = hsz[c],
            .use_t1 = (fl & 1) != 0,
            .avoiding = (fl & 2) != 0,
        };
    } else {
        const a = accRead(c);
        return .{
            .anx = a.ax / a.nf,
            .any = a.ay / a.nf,
            .anz = a.az / a.nf,
            .nf = a.nf,
            .sx = a.sx,
            .sy = a.sy,
            .sz = a.sz,
            .use_t1 = cti[c] != 0,
            .avoiding = (cod[c] - aversion) < 0.0,
        };
    }
}

// ------------------------------------------------------------------ phases

// Phase 1. `@memset` per column, rather than the baseline's single loop
// writing nine columns element by element: 3.14ms -> 0.72ms.
inline fn clearCells() void {
    accClear();
    @memset(cti, 0);
    @memset(cod, 0);
    occ_len = 0;
}

inline fn cellIndexScalar(px: f32, py: f32, pz: f32) u32 {
    const cx = std.math.clamp(@as(i32, @intFromFloat(px / cell_radius)), 0, axis_cells - 1);
    const cy = std.math.clamp(@as(i32, @intFromFloat(py / cell_radius)), 0, axis_cells - 1);
    const cz = std.math.clamp(@as(i32, @intFromFloat(pz / cell_radius)), 0, axis_cells - 1);
    return @bitCast((cz * axis_cells + cy) * axis_cells + cx);
}

// Phase 2a. The cell index is pure per-boid arithmetic with no cross-boid
// dependency, so splitting it out of the scatter lets it vectorise: 3.0ms for
// the quantise plus the scatter below, against 48.8ms for the two fused,
// despite the extra 400 KiB round trip through `bcell`.
fn hashPass() void {
    var i: usize = 0;
    var lo_acc: u32 = @intCast(cell_total - 1);
    var hi_acc: u32 = 0;
    if (hash_w > 1) {
        const w = hash_w;
        const V = @Vector(w, f32);
        const I = @Vector(w, i32);
        const U = @Vector(w, u32);
        // `/ 8.0` is exact for a power of two, so `* 0.125` is the same f32
        // value; LLVM performs this rewrite itself on the scalar path.
        const inv_radius: V = @splat(@as(f32, 1.0) / cell_radius);
        const lo: I = @splat(@as(i32, 0));
        const hi: I = @splat(axis_cells - 1);
        const stride: I = @splat(axis_cells);
        var vlo: U = @splat(@as(u32, cell_total - 1));
        var vhi: U = @splat(@as(u32, 0));
        while (i + w <= n_ent) : (i += w) {
            const px: V = bpx[i..][0..w].*;
            const py: V = bpy[i..][0..w].*;
            const pz: V = bpz[i..][0..w].*;
            const cx = @min(@max(@as(I, @intFromFloat(px * inv_radius)), lo), hi);
            const cy = @min(@max(@as(I, @intFromFloat(py * inv_radius)), lo), hi);
            const cz = @min(@max(@as(I, @intFromFloat(pz * inv_radius)), lo), hi);
            const idx = (cz * stride + cy) * stride + cx;
            const u: U = @bitCast(idx);
            bcell[i..][0..w].* = u;
            if (range_scan) {
                vlo = @min(vlo, u);
                vhi = @max(vhi, u);
            }
        }
        if (range_scan) {
            lo_acc = @reduce(.Min, vlo);
            hi_acc = @reduce(.Max, vhi);
        }
    }
    while (i < n_ent) : (i += 1) {
        const u = cellIndexScalar(bpx[i], bpy[i], bpz[i]);
        bcell[i] = u;
        if (range_scan) {
            lo_acc = @min(lo_acc, u);
            hi_acc = @max(hi_acc, u);
        }
    }
    // The occupied cells all lie inside [lo_acc, hi_acc] by construction, so
    // phase 3 can skip the rest of the 32768. With the AoS accumulator the
    // scan reads 32 bytes per cell, which is 1 MiB per frame over the full
    // grid; the boids in practice cover about a thousand consecutive indices.
    // Cells outside the range are provably empty, so this is bit-identical.
    scan_lo = lo_acc;
    scan_hi = hi_acc;
}

// Phase 2b. Strictly sequential in boid order: f32 add is not associative, so
// the visit order IS the checksum.
//
// Two things that look like wins here and are not. Both measured, both left
// behind their flags so the claim is reproducible:
//
//   `run_scatter` -- consecutive boids land in the same cell about eight at a
//   time (measured: mean run length 8.20, stable across all 100 frames), so
//   collapsing a run into register accumulation should replace a
//   store-to-load-forwarding chain with a shorter fadd chain. It costs 6ms
//   instead (36.3 -> 42.4). Both the run scan and the counted inner loop have
//   data-dependent trip counts, and two branch mispredicts per eight boids
//   outweigh what the shortened dependency chain returns.
//
//   `track_occupied` -- pushing first-touch cells onto a list lets phase 3
//   skip its 32768-cell scan. Saves 0.4ms there, costs 3.4ms here for the
//   extra compare-and-branch per boid. Net loss.
fn scatterPass() void {
    if (n_ent == 0) return;
    if (!run_scatter) {
        for (0..n_ent) |i| {
            const idx: usize = bcell[i];
            if (track_occupied and accEmpty(idx)) {
                occ[occ_len] = @intCast(idx);
                occ_len += 1;
            }
            accAdd(idx, bfx[i], bfy[i], bfz[i], bpx[i], bpy[i], bpz[i]);
        }
        return;
    }

    // Run-collapsed form. The accumulator is SEEDED FROM MEMORY at the start
    // of each run and stored back at the end, so a run of k boids evaluates
    // `(((m + f0) + f1) + ...)` -- exactly the association the per-boid form
    // produces. Reassociating here would change the checksum.
    var i: usize = 0;
    while (i < n_ent) {
        const c: usize = bcell[i];
        const start = i;
        var j = i + 1;
        while (j < n_ent and bcell[j] == c) : (j += 1) {}

        const a0 = accRead(c);
        if (track_occupied and a0.nf == 0) {
            occ[occ_len] = @intCast(c);
            occ_len += 1;
        }
        var ax = a0.ax;
        var ay = a0.ay;
        var az = a0.az;
        var sx = a0.sx;
        var sy = a0.sy;
        var sz = a0.sz;
        while (i < j) : (i += 1) {
            ax += bfx[i];
            ay += bfy[i];
            az += bfz[i];
            sx += bpx[i];
            sy += bpy[i];
            sz += bpz[i];
        }
        const k: f32 = @floatFromInt(j - start);
        if (aos_cells) {
            cacc[c] = CellV{ ax, ay, az, sx, sy, sz, a0.nf + k, 0.0 };
        } else {
            cax[c] = ax;
            cay[c] = ay;
            caz[c] = az;
            csx[c] = sx;
            csy[c] = sy;
            csz[c] = sz;
            ccount[c] = @intFromFloat(a0.nf + k);
        }
    }
}

fn hashScatterFused() void {
    var lo_acc: u32 = @intCast(cell_total - 1);
    var hi_acc: u32 = 0;
    for (0..n_ent) |i| {
        const px = bpx[i];
        const py = bpy[i];
        const pz = bpz[i];
        const u = cellIndexScalar(px, py, pz);
        const idx: usize = u;
        bcell[i] = u;
        if (range_scan) {
            lo_acc = @min(lo_acc, u);
            hi_acc = @max(hi_acc, u);
        }
        if (track_occupied and accEmpty(idx)) {
            occ[occ_len] = @intCast(idx);
            occ_len += 1;
        }
        accAdd(idx, bfx[i], bfy[i], bfz[i], px, py, pz);
    }
    scan_lo = lo_acc;
    scan_hi = hi_acc;
}

// Phase 3: DOTS' MergeCells, per cell. argmin ties go to the lower index.
//
// This is also where the per-boid loop invariants are computed: `a / n`,
// `f32(count)`, which target won, and whether the obstacle is inside the
// aversion radius. ~950 occupied cells per frame against 100k boids, so each
// of these moves from 100k evaluations to 950. Bit-identical -- same f32
// division, same operands, just evaluated once.
inline fn resolveCell(c: usize, fr: Frame) void {
    const a = accRead(c);
    const n = a.nf;
    const avg_x = a.sx / n;
    const avg_y = a.sy / n;
    const avg_z = a.sz / n;

    var nearest_target: i32 = 0;
    var nearest_target_dist = lengthsq(fr.t0x - avg_x, fr.t0y - avg_y, fr.t0z - avg_z);
    const d1 = lengthsq(fr.t1x - avg_x, fr.t1y - avg_y, fr.t1z - avg_z);
    if (d1 < nearest_target_dist) {
        nearest_target_dist = d1;
        nearest_target = 1;
    }

    const nearest_obstacle_dist = lengthsq(fr.obx - avg_x, fr.oby - avg_y, fr.obz - avg_z);
    const od = @sqrt(nearest_obstacle_dist);

    cti[c] = nearest_target;
    cod[c] = od;

    if (hoist_cell) {
        hnf[c] = n;
        hanx[c] = a.ax / n;
        hany[c] = a.ay / n;
        hanz[c] = a.az / n;
        hsx[c] = a.sx;
        hsy[c] = a.sy;
        hsz[c] = a.sz;
        hflags[c] = nearest_target | (if ((od - aversion) < 0.0) @as(i32, 2) else 0);
    }
}

fn resolvePass(fr: Frame) void {
    if (track_occupied) {
        for (occ[0..occ_len]) |c| resolveCell(c, fr);
    } else if (range_scan) {
        if (n_ent == 0) return;
        var c: usize = scan_lo;
        while (c <= scan_hi) : (c += 1) {
            if (accEmpty(c)) continue;
            resolveCell(c, fr);
        }
    } else {
        for (0..cell_total) |c| {
            if (accEmpty(c)) continue;
            resolveCell(c, fr);
        }
    }
}

// Phase 4, scalar. Used for the vector tail and for `steer_w == 1`.
fn steerScalarRange(from: usize, to: usize, fr: Frame) void {
    var i = from;
    while (i < to) : (i += 1) {
        const idx: usize = bcell[i];
        const px = bpx[i];
        const py = bpy[i];
        const pz = bpz[i];
        const fx = bfx[i];
        const fy = bfy[i];
        const fz = bfz[i];
        const ci = cellInputs(idx);

        const al = normalizesafe(ci.anx - fx, ci.any - fy, ci.anz - fz);
        const sp = normalizesafe(px * ci.nf - ci.sx, py * ci.nf - ci.sy, pz * ci.nf - ci.sz);
        const tx = if (ci.use_t1) fr.t1x else fr.t0x;
        const ty = if (ci.use_t1) fr.t1y else fr.t0y;
        const tz = if (ci.use_t1) fr.t1z else fr.t0z;
        const hd = normalizesafe(tx - px, ty - py, tz - pz);

        const os = normalizesafe(px - fr.obx, py - fr.oby, pz - fr.obz);
        const avoid_x = (fr.obx + os.x * aversion) - px;
        const avoid_y = (fr.oby + os.y * aversion) - py;
        const avoid_z = (fr.obz + os.z * aversion) - pz;

        const nm = normalizesafe(
            alignment_weight * al.x + separation_weight * sp.x + target_weight * hd.x,
            alignment_weight * al.y + separation_weight * sp.y + target_weight * hd.y,
            alignment_weight * al.z + separation_weight * sp.z + target_weight * hd.z,
        );

        const tf_x = if (ci.avoiding) avoid_x else nm.x;
        const tf_y = if (ci.avoiding) avoid_y else nm.y;
        const tf_z = if (ci.avoiding) avoid_z else nm.z;

        const nx = normalizesafe(
            fx + dt * (tf_x - fx),
            fy + dt * (tf_y - fy),
            fz + dt * (tf_z - fz),
        );
        bfx[i] = nx.x;
        bfy[i] = nx.y;
        bfz[i] = nx.z;
        bpx[i] = std.math.clamp(px + nx.x * move_dist, 0.0, pos_max);
        bpy[i] = std.math.clamp(py + nx.y * move_dist, 0.0, pos_max);
        bpz[i] = std.math.clamp(pz + nx.z * move_dist, 0.0, pos_max);
    }
}

fn steerPass(fr: Frame) void {
    var i: usize = 0;
    if (steer_w > 1) {
        const w = steer_w;
        const V = @Vector(w, f32);
        const B = @Vector(w, bool);

        const v_aversion: V = @splat(aversion);
        const v_dt: V = @splat(dt);
        const v_move: V = @splat(move_dist);
        const v_lo: V = @splat(@as(f32, 0.0));
        const v_hi: V = @splat(pos_max);
        const v_tw: V = @splat(target_weight);
        const v_obx: V = @splat(fr.obx);
        const v_oby: V = @splat(fr.oby);
        const v_obz: V = @splat(fr.obz);
        const v_t0x: V = @splat(fr.t0x);
        const v_t0y: V = @splat(fr.t0y);
        const v_t0z: V = @splat(fr.t0z);
        const v_t1x: V = @splat(fr.t1x);
        const v_t1y: V = @splat(fr.t1y);
        const v_t1z: V = @splat(fr.t1z);

        while (i + w <= n_ent) : (i += w) {
            const px: V = bpx[i..][0..w].*;
            const py: V = bpy[i..][0..w].*;
            const pz: V = bpz[i..][0..w].*;
            const fx: V = bfx[i..][0..w].*;
            const fy: V = bfy[i..][0..w].*;
            const fz: V = bfz[i..][0..w].*;
            const ix: [w]u32 = bcell[i..][0..w].*;

            // Per-lane gather. On AArch64 each of these is a single
            // `ld1 {v.s}[n]` -- load and insert in one instruction -- so the
            // gather costs the SAME instruction count as the scalar loads it
            // replaces, while everything downstream divides by `w`.
            var g_anx: [w]f32 = undefined;
            var g_any: [w]f32 = undefined;
            var g_anz: [w]f32 = undefined;
            var g_nf: [w]f32 = undefined;
            var g_sx: [w]f32 = undefined;
            var g_sy: [w]f32 = undefined;
            var g_sz: [w]f32 = undefined;
            var g_t1: [w]bool = undefined;
            var g_av: [w]bool = undefined;
            inline for (0..w) |l| {
                const ci = cellInputs(ix[l]);
                g_anx[l] = ci.anx;
                g_any[l] = ci.any;
                g_anz[l] = ci.anz;
                g_nf[l] = ci.nf;
                g_sx[l] = ci.sx;
                g_sy[l] = ci.sy;
                g_sz[l] = ci.sz;
                g_t1[l] = ci.use_t1;
                g_av[l] = ci.avoiding;
            }
            const anx: V = g_anx;
            const any: V = g_any;
            const anz: V = g_anz;
            const nf: V = g_nf;
            const sx: V = g_sx;
            const sy: V = g_sy;
            const sz: V = g_sz;
            const use_t1: B = g_t1;
            const avoiding: B = g_av;

            const al = normalizesafeV(w, anx - fx, any - fy, anz - fz);
            const sp = normalizesafeV(w, px * nf - sx, py * nf - sy, pz * nf - sz);

            const tx = @select(f32, use_t1, v_t1x, v_t0x);
            const ty = @select(f32, use_t1, v_t1y, v_t0y);
            const tz = @select(f32, use_t1, v_t1z, v_t0z);
            const hd = normalizesafeV(w, tx - px, ty - py, tz - pz);

            // `avoid` and `normal` are the two arms of one select, so a lane
            // only ever consumes one of them. When a whole group agrees, the
            // other arm's `normalizesafe` -- an fsqrt.4s plus an fdiv.4s,
            // which is what this loop is throughput-bound on -- is dead, and
            // is skipped. Every surviving lane is bit-identical; only
            // provably-discarded work disappears. Worth 5.7ms at w = 16.
            var tf_x: V = undefined;
            var tf_y: V = undefined;
            var tf_z: V = undefined;
            const any_avoid = if (skip_dead_arm) @reduce(.Or, avoiding) else true;
            const all_avoid = if (skip_dead_arm) @reduce(.And, avoiding) else false;

            if (all_avoid) {
                const os = normalizesafeV(w, px - v_obx, py - v_oby, pz - v_obz);
                tf_x = (v_obx + os[0] * v_aversion) - px;
                tf_y = (v_oby + os[1] * v_aversion) - py;
                tf_z = (v_obz + os[2] * v_aversion) - pz;
            } else if (!any_avoid) {
                // alignment_weight and separation_weight are 1.0; `1.0 * x` is
                // the identity for every value reachable here, and LLVM folds
                // it away.
                const nm = normalizesafeV(
                    w,
                    al[0] + sp[0] + v_tw * hd[0],
                    al[1] + sp[1] + v_tw * hd[1],
                    al[2] + sp[2] + v_tw * hd[2],
                );
                tf_x = nm[0];
                tf_y = nm[1];
                tf_z = nm[2];
            } else {
                const os = normalizesafeV(w, px - v_obx, py - v_oby, pz - v_obz);
                const avoid_x = (v_obx + os[0] * v_aversion) - px;
                const avoid_y = (v_oby + os[1] * v_aversion) - py;
                const avoid_z = (v_obz + os[2] * v_aversion) - pz;
                const nm = normalizesafeV(
                    w,
                    al[0] + sp[0] + v_tw * hd[0],
                    al[1] + sp[1] + v_tw * hd[1],
                    al[2] + sp[2] + v_tw * hd[2],
                );
                tf_x = @select(f32, avoiding, avoid_x, nm[0]);
                tf_y = @select(f32, avoiding, avoid_y, nm[1]);
                tf_z = @select(f32, avoiding, avoid_z, nm[2]);
            }

            const nx = normalizesafeV(
                w,
                fx + v_dt * (tf_x - fx),
                fy + v_dt * (tf_y - fy),
                fz + v_dt * (tf_z - fz),
            );

            bfx[i..][0..w].* = nx[0];
            bfy[i..][0..w].* = nx[1];
            bfz[i..][0..w].* = nx[2];
            bpx[i..][0..w].* = @max(@min(px + nx[0] * v_move, v_hi), v_lo);
            bpy[i..][0..w].* = @max(@min(py + nx[1] * v_move, v_hi), v_lo);
            bpz[i..][0..w].* = @max(@min(pz + nx[2] * v_move, v_hi), v_lo);
        }
    }
    steerScalarRange(i, n_ent, fr);
}

// ------------------------------------------------------------- frame loop
var ph: [6]u64 = .{0} ** 6;
var ph_prev: std.time.Instant = undefined;

inline fn phBegin() void {
    if (phase_timing) ph_prev = std.time.Instant.now() catch unreachable;
}
inline fn phMark(comptime slot: usize) void {
    if (!phase_timing) return;
    const now = std.time.Instant.now() catch unreachable;
    ph[slot] += now.since(ph_prev);
    ph_prev = now;
}

fn runFrames(frames: usize) void {
    for (0..frames) |frame| {
        phBegin();
        // Sawtooth target and obstacle motion -- no trigonometry, because
        // libm sin/cos differ in the last ulp between toolchains.
        const fr = Frame{
            .t0x = @floatFromInt((frame * 3) % 256),
            .t0y = 128.0,
            .t0z = @floatFromInt((frame * 5) % 256),
            .t1x = @floatFromInt((frame * 7) % 256),
            .t1y = 160.0,
            .t1z = @floatFromInt((frame * 11) % 256),
            .obx = @floatFromInt((frame * 13) % 256),
            .oby = 128.0,
            .obz = @floatFromInt((frame * 17) % 256),
        };
        phMark(0);
        clearCells();
        phMark(1);
        if (fuse_hash_scatter) {
            hashScatterFused();
            phMark(2);
        } else {
            hashPass();
            phMark(2);
            scatterPass();
        }
        phMark(3);
        resolvePass(fr);
        phMark(4);
        steerPass(fr);
        phMark(5);
    }
}

fn reportPhases() void {
    if (!phase_timing) return;
    const names = [_][]const u8{ "actors", "clear", "hash", "scatter", "resolve", "steer" };
    var total: u64 = 0;
    for (ph) |v| total += v;
    for (names, ph) |nm, v| {
        std.debug.print("zig_steelman boids_phase {s}: {d} ns ({d:.3} ms)\n", .{ nm, v, @as(f64, @floatFromInt(v)) / 1_000_000.0 });
    }
    std.debug.print("zig_steelman boids_phase phase_total: {d} ns ({d:.3} ms)\n", .{ total, @as(f64, @floatFromInt(total)) / 1_000_000.0 });
}

fn initWorld(entities: usize) void {
    n_ent = entities;
    for (0..entities) |i| {
        bpx[i] = @floatFromInt(i % 256);
        bpy[i] = @floatFromInt((i / 256) % 256);
        bpz[i] = @floatFromInt((i / 65536) % 256);
        const forward = normalizesafe(
            @as(f32, @floatFromInt(i % 13)) - 6.0,
            @as(f32, @floatFromInt(i % 17)) - 8.0,
            @as(f32, @floatFromInt(i % 7)) - 3.0,
        );
        bfx[i] = forward.x;
        bfy[i] = forward.y;
        bfz[i] = forward.z;
        bcell[i] = 0;
    }
}

fn checksum() u64 {
    var sink: u64 = 0;
    for (0..n_ent) |i| {
        sink +%= @as(u64, @intFromFloat(@abs(bpx[i]))) *% 31;
        sink +%= @as(u64, @intFromFloat(@abs(bpy[i]))) *% 17;
        sink +%= @as(u64, @intFromFloat(@abs(bpz[i]))) *% 13;
    }
    return sink;
}

// -------------------------------------------------------------------- CLI
const Config = struct {
    entities: usize = 100_000,
    frames: usize = 100,
    observers: usize = 25,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config{};
    {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();
        _ = args.next();
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--scenario")) {
                const value = args.next() orelse return error.MissingScenario;
                if (!std.mem.eql(u8, value, "boids")) return error.UnsupportedScenario;
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
    }
    if (config.entities > max_entities) return error.TooManyEntities;

    // Init is outside the timed region, by contract.
    initWorld(config.entities);

    const start = std.time.nanoTimestamp();
    runFrames(config.frames);
    const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
    reportPhases();

    const sink = checksum();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_file.interface;
    try stdout.print("{{\"impl\":\"zig_steelman\",\"scenario\":\"boids\",\"entities\":{},\"frames\":{},\"observers\":{},\"elapsed_ns\":{},\"sink\":{}}}\n", .{
        config.entities,
        config.frames,
        config.observers,
        elapsed,
        sink,
    });
    try stdout.flush();
}
