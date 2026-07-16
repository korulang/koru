// The World in Koru — entry 4.
// Doorway: Go's `mu.Lock(); defer mu.Unlock()` — the canonical use of defer:
// take a lock and schedule its release at scope exit, so it runs no matter
// which path the function takes.
//
// Here in Koru you go one better: you don't write the release at all. `lock`
// mints a token whose TYPE carries the `<held!>` obligation, and `unlock` is
// the only event that consumes `<!held>`. If you never call it, the compiler
// AUTO-INSERTS the unlock at scope exit — Koru writes your `defer` for you, and
// you cannot leak the lock. When two locks are held, the inserted releases
// unwind LIFO (inner released first) — the same order `defer` guarantees, for
// the same reason: an inner resource may depend on the outer still being live.
//
// A mutex is a SYMMETRIC resource: its lifecycle is held -> released, with the
// real work happening on the state the lock guards (orthogonal to the token).
// So `lock`/`unlock` is the honest model — no invented middle state.
import std/io

pub event lock { name: []const u8 } -> []const u8<held!>
lock -> name

pub event unlock { name: []const u8<!held> }
unlock = std/io:print.ln("unlock {{ name:s }}")

// Two locks held; NO explicit unlock written. Auto-discharge inserts both at
// scope exit, LIFO: inner released before outer.
lock(name: "outer"): outer |> lock(name: "inner"): inner |> std/io:print.ln("critical section")
