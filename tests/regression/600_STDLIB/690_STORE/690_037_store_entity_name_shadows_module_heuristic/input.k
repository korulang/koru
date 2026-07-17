// Pins the KNOWN LIMITATION of the writeFieldType co-location heuristic
// (phantomModuleLooksLikeTypeHome, landed with the cross-module fix f1b0d561):
// it decides "the base type lives in the phantom's module" by matching the type
// NAME against the module's last segment (`Field`↔`field`, `List_i64`↔`list`).
// That is a name heuristic, not real type-home resolution — so an entity NAMED
// like a module collides. Here `[entity(store)]` synthesizes the type `Store`;
// take mints `<std/store:taken>`; and phantomModuleLooksLikeTypeHome("Store",
// "std/store") FALSE-POSITIVES ("Store" ≈ "store"), so the discharger's bare
// `Store` is mis-qualified to `koru_std.koru_store.Store` (which does not exist)
// instead of the user-local `Store`.
//
// This is same-file — no cross-module involved. Entity naming alone must never
// affect resolution, so this SHOULD run and print "despawned a thing"; the
// heuristic's replacement is a real type->module registry. Contrast 690_034
// (entity `enemy` → `Enemy`, no name collision).
import std/io
import std/store

[entity(store)]std/store:new(things) { hp: i64 }

pub event despawn-thing { thing: Store<std/store:!taken> }
despawn-thing = std/io:print.ln("despawned a thing")

std/store:insert(things) { hp: 9 }
| row r |> std/store:take(things[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}") |> despawn-thing(thing: i)
