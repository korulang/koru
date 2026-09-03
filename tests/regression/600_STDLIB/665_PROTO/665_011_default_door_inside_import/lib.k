// A compound declared through the default door from inside a library
// module. Same spelling as the entry-file door (660_030); the pipeline
// rewrites it regardless of which module spells it.
import std/proto

std/proto:float(Health)

std/proto(Scout) {
    health: Health
}
