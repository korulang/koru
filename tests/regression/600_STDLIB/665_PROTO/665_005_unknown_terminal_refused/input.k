// A compound field cannot invent an identity by spelling a new word. `Mystery`
// is neither a scalar material nor a declared terminal, so the declaration
// itself must refuse it. This is the strict half of composition: named
// sameness is intentional, never inferred from an unregistered name.
import std/proto

std/proto(Player) {
    health: Mystery
}
