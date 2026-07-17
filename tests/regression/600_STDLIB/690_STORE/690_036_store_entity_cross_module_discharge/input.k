// Pins the CROSS-MODULE entity discharger. An [entity] store synthesizes Enemy
// and its `take` mints the taken-obligation; the despawn handler lives in a
// SEPARATE module (despawner.k) and consumes the qualified state
// <std/store:!taken> (bare state is illegal outside the declaring module —
// 330_088). Discharge is LEFT IMPLICIT: auto-discharge must resolve the sole
// consumer ACROSS the module boundary and insert it.
//
// Root of the RED (grounded in frag-std-store-design.md rung 2 + the observed
// error): the store today mints a BARE, LOCAL `taken` (store.kz ~1312),
// deliberately unqualified to dodge the emitter's writeFieldType fallback
// (emitter_helpers ~848 qualifies a base type with its PHANTOM's module — right
// for Field<std/field:field> where type and state co-locate, wrong when base
// type and state live in different modules, as Enemy/taken do). Because the mint
// is main-local, no other module can name it: this file's qualified
// <std/store:!taken> never unifies with the bare <taken!>, so auto-discharge
// reports KORU030 "No event accepts <!taken>". `const Enemy` is also emitted
// private, so a sibling could not reference the type even once the state
// resolves. FIX: unpark the writeFieldType base-type/state orthogonality, mint
// qualified <std/store:taken!>, make Enemy pub, migrate 690_023/034/035 to the
// qualified consume. Sibling frontier to 330_087 / 330_089.
import std/io
import std/store
import app/despawner

[entity(enemy)]std/store:new(enemies) { hp: i64 }

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}")
