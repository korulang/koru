import std/store

// The store is declared HERE, in an imported module — not in the entry file.
// Both the write and the read stay inside this module, so the cell and the
// synthesized accessors all belong to one namespace and no prefix is needed.
std/store:new(cache) { v: 1[i64] }

pub tor bump {}
bump = std/store:stored { cache.v: 10 }

pub tor peek {} -> i64
peek -> cache.v
