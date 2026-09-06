import std/io
import std/proto
import std/store

std/proto:int(Strength)
std/proto:int(Mana)

std/proto(Player) {
    str: Strength
    mana: Mana
}

std/store:new(Player, capacity: 8) { Player }

std/store:insert(Player) { str: 18, mana: 12 }

std/store:query(Player)
! query e when e is Player |> std/io:print.ln("p {{ e.str:d }}")
