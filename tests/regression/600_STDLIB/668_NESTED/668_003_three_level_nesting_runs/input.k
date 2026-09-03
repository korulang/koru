// Nesting recurses, it is not one level special-cased: Span lives inside
// Position lives inside Player, three deep, and the declaration is accepted
// with every leaf keeping its identity. The nested span sits first, so the
// walk feeds synthesis its first leaf two expansions down.
import std/io
import std/proto
import std/list

std/proto:float(Health)

pub tor report-health { health: Health } -> Health

report-health -> health

std/proto(Span) {
    lo: f32
    hi: f32
}

std/proto(Position) {
    span: Span
    x: f32
}

std/proto(Player) {
    pos: Position
    health: Health
}

std/list:new(Player)
| list players |> std/list:push(xs: players, v: 7.5) |> std/list:pop(xs: players)
    | item player |> report-health(health: player): player_out |> std/io:print.ln("player {{ player_out:d }}") |> std/list:free(xs: players)
    | empty |> std/io:print.ln("player EMPTY") |> std/list:free(xs: players)
| err e |> std/io:print.ln("ERR {{ e:s }}")
