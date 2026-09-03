// The shared terminal keeps its identity through nesting: Player and Enemy
// both expand a `pos: Position` alongside their direct `health: Health`,
// and popped values from both lists flow into the one Health-typed
// receiver. Chains preserve what terminals promise globally.
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
    health: Health
    pos: Position
}

std/proto(Enemy) {
    health: Health
    pos: Position
}

std/list:new(Player)
| list players |> std/list:push(xs: players, v: 98.6) |> std/list:pop(xs: players)
    | item player |> report-health(health: player): player_out |> std/io:print.ln("player {{ player_out:d }}") |> std/list:free(xs: players)
    | empty |> std/io:print.ln("player EMPTY") |> std/list:free(xs: players)
| err e |> std/io:print.ln("ERR {{ e:s }}")

std/list:new(Enemy)
| list enemies |> std/list:push(xs: enemies, v: 72.5) |> std/list:pop(xs: enemies)
    | item enemy |> report-health(health: enemy): enemy_out |> std/io:print.ln("enemy {{ enemy_out:d }}") |> std/list:free(xs: enemies)
    | empty |> std/io:print.ln("enemy EMPTY") |> std/list:free(xs: enemies)
| err e |> std/io:print.ln("ERR {{ e:s }}")
