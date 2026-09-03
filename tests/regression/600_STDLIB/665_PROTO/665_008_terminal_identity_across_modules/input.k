// The caller does not redeclare the terminal. If the imported `Health` were
// invisible, the compound would refuse `Health` as an unknown terminal. Its
// successful erasure proves cross-module resolution at the registry layer;
// using the emitted alias across the boundary is separate consumer work.
import app/domain
import std/io
import std/proto

std/proto(Player) {
    health: Health
}

std/io:print.ln("declared")
