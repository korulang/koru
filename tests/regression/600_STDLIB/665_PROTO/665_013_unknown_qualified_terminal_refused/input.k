// A qualified reference must resolve to a real declaration. `app/ghost`
// mints nothing, so the field is refused at the declaration like any
// unregistered word — qualification is addressing, not invention.
import std/proto

std/proto(Player) {
    health: app/ghost:Health
}
