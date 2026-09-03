// A compound may name a declared terminal instead of repeating its material.
// `Health` is one registered identity, while `Player` is one compound entry
// that references it. The list surface then uses the terminal alias exactly
// as it uses a scalar: the container stores `Health`, not a second float
// concept smuggled in by spelling.
import std/io
import std/proto
import std/list

std/proto:float(Health)

std/proto(Player) {
    health: Health
}

std/list:new(Player)
| list xs |> std/list:push(xs, v: 98.6) |> std/list:len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
