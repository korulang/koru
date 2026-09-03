// The same raw material in two compounds is not a shared identity. These two
// `health: f32` fields are spelled the same way, but no terminal names them
// and neither one can prove sameness. Each proto therefore gets its own
// registry entry, its own `List_` container, and its own rows. A future layout
// layer may only merge what a shared terminal proves identical; this pin
// guards the declaration half of that rule.
import std/io
import std/proto
import std/list

std/proto(Player) {
    health: f32
}

std/proto(Enemy) {
    health: f32
}

std/list:new(Player)
| list players |> std/list:push(xs: players, v: 1.5) |> std/list:pop(xs: players)
    | item player |> std/io:print.ln("player {{ player:d }}") |> std/list:free(xs: players)
    | empty |> std/io:print.ln("player EMPTY") |> std/list:free(xs: players)
| err e |> std/io:print.ln("ERR {{ e:s }}")

std/list:new(Enemy)
| list enemies |> std/list:push(xs: enemies, v: 2.5) |> std/list:pop(xs: enemies)
    | item enemy |> std/io:print.ln("enemy {{ enemy:d }}") |> std/list:free(xs: enemies)
    | empty |> std/io:print.ln("enemy EMPTY") |> std/list:free(xs: enemies)
| err e |> std/io:print.ln("ERR {{ e:s }}")
