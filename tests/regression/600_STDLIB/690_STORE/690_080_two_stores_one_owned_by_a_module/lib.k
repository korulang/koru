import std/store

// The module owns `cache` — declared, written and read entirely in here, as in
// 690_079. What differs is only what the ENTRY file does alongside it.
std/store:new(cache) { v: 1[i64] }

pub tor bump {}
bump = std/store:stored { cache.v: 10 }

pub tor peek {} -> i64
peek -> cache.v
