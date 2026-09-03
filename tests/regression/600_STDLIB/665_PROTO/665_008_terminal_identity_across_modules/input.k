// A compound names another home's terminal by address. The entry file mints
// no Health of its own, so the bare name would be unknown here — the field
// spells `app/domain:Health`, and its successful erasure proves qualified
// resolution at the registry layer.
import app/domain
import std/io
import std/proto

std/proto(Player) {
    health: app/domain:Health
}

std/io:print.ln("declared")
