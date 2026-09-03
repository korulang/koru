// A compound may name another compound: `pos: Position` expands to its
// scalar leaves, each keeping its identity — Health stays the shared
// terminal, raw leaves stay positional. Position sits FIRST, so expansion
// feeds synthesis its first leaf; without the walk the emitter would name
// an undeclared `Position` one stage later. The push value is f32-exact:
// pos.x is f32, and 98.6 is not representable there.
import std/io
import std/proto
import std/list

std/proto:float(Health)

pub tor report-health { health: Health } -> Health

report-health -> health

std/proto(Position) {
    x: f32
    y: f32
}

std/proto(Player) {
    pos: Position
    health: Health
}

std/list:new(Player)
| list players |> std/list:push(xs: players, v: 98.5) |> std/list:pop(xs: players)
    | item player |> report-health(health: player): player_out |> std/io:print.ln("player {{ player_out:d }}") |> std/list:free(xs: players)
    | empty |> std/io:print.ln("player EMPTY") |> std/list:free(xs: players)
| err e |> std/io:print.ln("ERR {{ e:s }}")
