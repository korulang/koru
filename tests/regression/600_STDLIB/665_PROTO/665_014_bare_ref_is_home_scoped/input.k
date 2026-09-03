// A bare ref names this home's terminal or nothing. The entry mints no
// Health of its own, so bare `health: Health` is unknown even with two
// declarations elsewhere — homes are never searched, only addressed.
import app/alpha
import app/beta
import std/proto

std/proto(Player) {
    health: Health
}
