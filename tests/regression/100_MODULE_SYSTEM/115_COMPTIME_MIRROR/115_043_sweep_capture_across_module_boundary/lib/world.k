// Components: the store is declared HERE, in its own module.
import std/store

std/store:new(items, capacity: 8) { v: i64 }

pub tor seed {}
seed = std/store:insert(items) { v: 10 }
