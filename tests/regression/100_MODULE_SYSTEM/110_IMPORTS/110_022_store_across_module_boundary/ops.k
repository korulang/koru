import std/store

// Read a store declared in the ENTRY.
pub tor peek {} -> i64
peek -> s.v

// Write a store declared in the ENTRY.
pub tor bump {}
bump = std/store:stored { s.v: 42 }
