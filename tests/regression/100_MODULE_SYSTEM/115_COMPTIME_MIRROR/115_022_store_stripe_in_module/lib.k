import std/io
import std/store

std/store:new(game) { hp: 0[i64] }

std/store:watch(game)
! hp h |> std/io:print.ln("hp {{ h:d }}")

pub tor write {}
write = std/store:stored { game.hp: 5 }

pub tor fire {}
fire = std/store:stripe(game)
