// A store-view is the projection join. `new(Player)` / `new(Enemy)` pack
// each proto at that store's root (seed names the proto; leaves keep proto
// field names — `str`, not `Player.str`). The view lists the stores; that
// list is the kind vocabulary. Projection is (path-from-that-root, type):
// `str: Strength` meets across the view. `mana` / `armor` stay private.
// Insert and obligations stay on the logical store. Query/stripe of the
// view is where `e is Player` means anything. A view is not a container —
// no capacity, no allocation, no insert; the rows live in the member
// stores. A store in no view keeps its own layout (285/286).
import std/io
import std/proto
import std/store

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

std/store:new(Player, capacity: 8) { Player }
std/store:new(Enemy, capacity: 8) { Enemy }

std/store:view(Entities) {
    Player
    Enemy
}

std/store:insert(Player) { str: 18, mana: 12 }
std/store:insert(Enemy) { str: 10, armor: 5 }

std/store:query(Entities)
! query e |> std/io:print.ln("entity {{ e.str:d }}")

std/store:query(Entities)
! query e when e is Player |> std/io:print.ln("player {{ e.str:d }} {{ e.mana:d }}")

std/store:query(Entities)
! query e when e is Enemy |> std/io:print.ln("enemy {{ e.str:d }} {{ e.armor:d }}")
