// The store is a PURE-Koru surface: this whole program — new, the reference
// reactive-attach with a guard, and writes — is a `.k` file with no `` anywhere.
// The tildes in the .kz store tests were vestigial; nothing about the store's
// surface requires them.
import std/io
import std/store

std/store:new(game) { hp: 0[i64] }

std/store(game)
! hp h when h < 10 |> std/io:print.ln("Low hp {{ h:d }}")

std/store:stored { game.hp: 5 }
std/store:stored { game.hp: 15 }
std/store:stored { game.hp: 3 }
