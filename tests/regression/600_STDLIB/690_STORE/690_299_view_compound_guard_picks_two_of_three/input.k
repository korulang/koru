// A compound `is`-guard over a THREE-member view: `e is Player or e is Enemy`
// picks two of three. The guard proves members by the UNION of positively
// named members (guardProvenMembers), and the emitter skips unproven members
// at emit time — the Boss loop is never generated, not merely filtered. The
// surviving loops' guards fold to constants. Negative-cost filtering: the
// narrowed query runs only the chosen members' loops.
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
! query e when e is Player or e is Enemy |> std/io:print.ln("entity {{ e.str:d }}")
