// Negating an `is`-guard on a view: `e is not Boss` sweeps every member
// EXCEPT Boss. Canonical spelling (Lars-ruled 2026-09-06): `is not` after
// the binding — parallel to `e is Player`, one word inserted; the store
// transform rewrites it to `e.kind != <ordinal>`. The `!(e is Boss)` spelling
// fails at file parse (PARSE003 — a grouped expression is strict and `is` is
// not an expression operator); the `! e is Boss` spelling mis-lowers; both
// were dead, unpinned since the 690_278-280 is-sugar cluster was retired.
// The negated guard proves NO member (every other member can match), so all
// member loops are emitted; the excluded member's guard is a constant false
// and the optimizer eliminates the loop — the negative-cost read applies in
// reverse.
import std/io
import std/proto
import std/store

std/proto:int(Strength)
std/proto:int(Mana)
std/proto:int(Armor)
std/proto:int(Rage)

std/proto(Player) {
    str: Strength
    mana: Mana
}

std/proto(Enemy) {
    str: Strength
    armor: Armor
}

std/proto(Boss) {
    str: Strength
    rage: Rage
}

std/store:new(Player, capacity: 8) { Player }
std/store:new(Enemy, capacity: 8) { Enemy }
std/store:new(Boss, capacity: 8) { Boss }

std/store:view(Entities) {
    Player
    Enemy
    Boss
}

std/store:insert(Player) { str: 18, mana: 12 }
std/store:insert(Enemy) { str: 10, armor: 5 }
std/store:insert(Boss) { str: 42, rage: 1 }

std/store:query(Entities)
! query e when e is not Boss |> std/io:print.ln("entity {{ e.str:d }}")
