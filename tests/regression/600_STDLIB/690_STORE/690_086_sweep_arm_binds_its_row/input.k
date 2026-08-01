// PINS: a sweep arm BINDS the row it visits, and every reference goes through
// that binding. Ruled by Lars 2026-07-28.
//
// THE RULESET this pin heads (siblings pin the rest):
//   1. A sweep/query/preorder arm binds its row, the way `! as acc` binds
//      capture's cell (control.kz:186 declares `! as *`; the transform reads
//      `cont.binding` and threads that ONE name everywhere).
//   2. References go through the binding: `e.v`.
//   3. `stored` targets are uniformly `<row>.<field>`. A capacity-1 store's
//      name IS its only row, which is why `ui.done` and `e.v` are the same
//      shape rather than two different kinds of thing.
//   4. Resolution order: bindings (innermost first) -> module-local stores ->
//      `[global(name)]` stores.
//   5. Shadowing is ALLOWED, matching every other branch binding. A store is
//      not a special case.
//   6. Stores stay module-private by default. `[global(name)]` exports one
//      under a comptime duplication-checked name — access control by opt-in,
//      never by grammar. `[entity(enemy)|global(enemies)]` composes.
//   7. `entity` stops existing.
//
// WHY. `entity` was never designed; it is the word a construct reaches for when
// it has no binder to resolve against. Its costs were measured, not theorised:
// nested sweeps resolved a READ to the inner store and a WRITE to the outer one
// in the same arm (690_087), because the rewrite matched the literal token
// `entity` across a subtree with no scope. Two bindings are two tokens, so the
// ambiguity disappears without any scoping rule being written.
//
// The sibling constructs already do this. `for` declares `! each *`, `capture`
// declares `! as *` — both `[keyword|comptime|transform]`, the same annotation
// sweep carries. Being a comptime transform is not why sweep skipped it.
import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }

std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

std/store:query(items)
! query e |> std/io:print.ln("v {{ e.v:d }}")
