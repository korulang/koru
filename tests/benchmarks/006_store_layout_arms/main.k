// Three declared layouts, one logical workload: sweep every entity and sum
// the shared `str` leaf; then the player-narrowed subset, guarded.
//
// The post "Store Views and Lone Packing" claims the view's unguarded query
// compiles to exactly the member sweeps — sequential loops, no tag column,
// no discrimination cost ("the emitted shape shows it below"). This certifies
// that claim end-to-end (codegen + LLVM, not just emitted Zig) and measures
// the one decision the ladder leaves open: separate extents vs one
// hand-declared union extent.
//
//   separate     — two lone stores, swept separately            (product)
//   view         — the same stores through std/store:view       (logical sum)
//   union        — ONE store, kind column, all leaves folded    (physical sum,
//                  declared by hand — the pooled std/store:kind set that
//                  690_296 pins is aspirational, not landed)
//   view_player  — view narrowed `when e is Player`
//   union_player — union narrowed `when e.kind == 1`
//
// The sinks are the oracle: every unguarded arm must sum the SAME str total
// (players + enemies), every guarded arm the same player subset. Divergence
// means a wrong layout, not a slow one.
//
// Koru-only; same JSON-line contract as 003_ecs_reactive. `elapsed_ns` is
// the whole timed run of `frames` sweeps; `sink` is the anti-DCE checksum,
// read back untimed after the run.
import std/io
import std/store
import std/proto
import std/time

// --- the population --------------------------------------------------------
// 60 000 players + 40 000 enemies. A player has str + mana; an enemy has
// str + armor. str is the shared leaf — the leaf the view meets on and the
// union folds.

std/proto:int(Strength)
std/proto:int(Mana)
std/proto:int(Armor)

std/proto(Player) {
    str: Strength
    mana: Mana
}

std/proto(Enemy) {
    str: Strength
    armor: Armor
}

std/store:new(Player, capacity: 100000) { Player }
std/store:new(Enemy, capacity: 100000) { Enemy }

std/store:view(Entities) {
    Player
    Enemy
}

std/store:new(Union, capacity: 100000) { kind: i64, str: i64, mana: i64, armor: i64 }

// --- state -----------------------------------------------------------------
std/store:new(cfg) { np: 60000[i64], ne: 40000[i64], frames: 1000[i64] }
std/store:new(acc) { s1: 0[i64], s2: 0[i64], s3: 0[i64], sg2: 0[i64], sg3: 0[i64] }
std/store:new(tm) { t1: 0[i64], t2: 0[i64], t3: 0[i64], tg2: 0[i64], tg3: 0[i64] }

// --- init (untimed) --------------------------------------------------------
tor init-players {}
init-players = for(0..@as(usize, @intCast(cfg.np)))
    ! each i |> std/store:insert(Player) { str: @as(i64, @intCast(@mod(i * 7, 1000))), mana: @as(i64, @intCast(@mod(i * 3, 500))) }

tor init-enemies {}
init-enemies = for(0..@as(usize, @intCast(cfg.ne)))
    ! each i |> std/store:insert(Enemy) { str: @as(i64, @intCast(@mod(i * 13, 1000))), armor: @as(i64, @intCast(@mod(i * 5, 300))) }

tor init-union-p {}
init-union-p = for(0..@as(usize, @intCast(cfg.np)))
    ! each i |> std/store:insert(Union) { kind: 1, str: @as(i64, @intCast(@mod(i * 7, 1000))), mana: @as(i64, @intCast(@mod(i * 3, 500))), armor: 0 }

tor init-union-e {}
init-union-e = for(0..@as(usize, @intCast(cfg.ne)))
    ! each i |> std/store:insert(Union) { kind: 2, str: @as(i64, @intCast(@mod(i * 13, 1000))), mana: 0, armor: @as(i64, @intCast(@mod(i * 5, 300))) }

tor init {}
init = init-players() |> init-enemies() |> init-union-p() |> init-union-e()

// --- the sweeps ------------------------------------------------------------
// Arm 1: two lone stores, two sweeps, no polymorphism.
tor sweep-separate-p {}
sweep-separate-p = std/store:query(Player)
! query e |> std/store:stored { acc.s1: acc.s1 + e.str }

tor sweep-separate-e {}
sweep-separate-e = std/store:query(Enemy)
! query e |> std/store:stored { acc.s1: acc.s1 + e.str }

// Arm 2: one view query — one spelling; per the post, exactly the two loops
// above, fed from the same projection.
tor sweep-view {}
sweep-view = std/store:query(Entities)
! query e |> std/store:stored { acc.s2: acc.s2 + e.str }

// Arm 3: one union sweep over one extent.
tor sweep-union {}
sweep-union = std/store:query(Union)
! query e |> std/store:stored { acc.s3: acc.s3 + e.str }

// Guarded: the player subset. The view's `is` folds to a constant compare;
// the union's `kind == 1` is a real column compare.
tor sweep-view-p {}
sweep-view-p = std/store:query(Entities)
! query e when e is Player |> std/store:stored { acc.sg2: acc.sg2 + e.str }

tor sweep-union-p {}
sweep-union-p = std/store:query(Union)
! query e when e.kind == 1 |> std/store:stored { acc.sg3: acc.sg3 + e.str }

// --- timed runs -------------------------------------------------------------
tor arm1-frame {}
arm1-frame = sweep-separate-p() |> sweep-separate-e()

tor arm2-frame {}
arm2-frame = sweep-view()

tor arm3-frame {}
arm3-frame = sweep-union()

tor arm2g-frame {}
arm2g-frame = sweep-view-p()

tor arm3g-frame {}
arm3g-frame = sweep-union-p()

tor run-1 {}
run-1 = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> arm1-frame()

tor run-2 {}
run-2 = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> arm2-frame()

tor run-3 {}
run-3 = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> arm3-frame()

tor run-2g {}
run-2g = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> arm2g-frame()

tor run-3g {}
run-3g = for(0..@as(usize, @intCast(cfg.frames)))
    ! each _ |> arm3g-frame()

tor tp-1 {}
tp-1 = std/time:now(): t |> run-1() |> std/time:elapsed(start: t): d
    |> std/store:stored { tm.t1: tm.t1 + @as(i64, @intCast(d.ns)) }

tor tp-2 {}
tp-2 = std/time:now(): t |> run-2() |> std/time:elapsed(start: t): d
    |> std/store:stored { tm.t2: tm.t2 + @as(i64, @intCast(d.ns)) }

tor tp-3 {}
tp-3 = std/time:now(): t |> run-3() |> std/time:elapsed(start: t): d
    |> std/store:stored { tm.t3: tm.t3 + @as(i64, @intCast(d.ns)) }

tor tp-2g {}
tp-2g = std/time:now(): t |> run-2g() |> std/time:elapsed(start: t): d
    |> std/store:stored { tm.tg2: tm.tg2 + @as(i64, @intCast(d.ns)) }

tor tp-3g {}
tp-3g = std/time:now(): t |> run-3g() |> std/time:elapsed(start: t): d
    |> std/store:stored { tm.tg3: tm.tg3 + @as(i64, @intCast(d.ns)) }

// --- emit -------------------------------------------------------------------
tor emit {}
emit = std/io:print.ln("{\"arm\":\"separate\",\"elapsed_ns\":{{ tm.t1:d }},\"sink\":{{ acc.s1:d }}}")
    |> std/io:print.ln("{\"arm\":\"view\",\"elapsed_ns\":{{ tm.t2:d }},\"sink\":{{ acc.s2:d }}}")
    |> std/io:print.ln("{\"arm\":\"union\",\"elapsed_ns\":{{ tm.t3:d }},\"sink\":{{ acc.s3:d }}}")
    |> std/io:print.ln("{\"arm\":\"view_player\",\"elapsed_ns\":{{ tm.tg2:d }},\"sink\":{{ acc.sg2:d }}}")
    |> std/io:print.ln("{\"arm\":\"union_player\",\"elapsed_ns\":{{ tm.tg3:d }},\"sink\":{{ acc.sg3:d }}}")

init() |> tp-1() |> tp-2() |> tp-3() |> tp-2g() |> tp-3g() |> emit()
