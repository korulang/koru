// A view sweep whose body WRITES to another store, reading the shared leaf in
// the write expression. 690_287's sweep body is a print.ln call: the read path
// threads the leaf into the handler input and each member loop binds it. A
// stored-write body took the .live lowering instead — the RHS re-read the leaf
// from `__koru_store_Entities.str[...]`, a store that does not exist (a view
// has no backing array), and the backend refused with `use of undeclared
// identifier '__koru_store_Entities'`. The write side must thread the leaf
// exactly like the read side: the projected value, bound per member loop.
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

std/store:new(acc) { sink: 0[i64] }

std/store:insert(Player) { str: 18, mana: 12 }
std/store:insert(Enemy) { str: 10, armor: 5 }

std/store:query(Entities)
! query e |> std/store:stored { acc.sink: acc.sink + e.str }

std/io:print.ln("sink {{ acc.sink:d }}")
