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

std/store:set(Entities) {
    Player
    Enemy
}

std/store:insert(Player) { str: 18, mana: 12 }
std/store:insert(Enemy) { str: 10, armor: 5 }

std/store:query(Entities)
! query e when e is Bogus |> std/io:print.ln("x {{ e.str:d }}")
