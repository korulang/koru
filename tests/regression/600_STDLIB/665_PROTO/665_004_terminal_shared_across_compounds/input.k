// One terminal can be referenced by several compounds without being
// redeclared. `Player` and `Enemy` do not each mint a separate health idea:
// both name the registered `Health`, and both pop values that the same
// `Health`-typed receiver accepts. The registry distinguishes declarations
// from references; references compose.
import std/io
import std/proto
import std/list

std/proto:float(Health)

pub tor report-health { health: Health } -> Health

report-health -> health

std/proto(Player) {
    health: Health
}

std/proto(Enemy) {
    health: Health
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
