// A lone store PACKS. Two placements of one proto are two subgraphs, not
// a union and not a fold: `left: Limb` and `right: Limb` mint two Health
// cells whose names are the DAG paths (`left.health`, `right.health`).
// Query `e.left.health` is one packed leaf, not a pointer walk. Folding
// same path+type across stores is a store-set act — not this file.
import std/io
import std/proto
import std/store

std/proto:int(Health)

std/proto(Limb) {
    health: Health
}

std/store:new(body, capacity: 8) { left: Limb, right: Limb }

std/store:insert(body) { left.health: 10, right.health: 20 }

std/store:query(body)
! query e |> std/io:print.ln("left {{ e.left.health:d }}")

std/store:query(body)
! query e |> std/io:print.ln("right {{ e.right.health:d }}")
