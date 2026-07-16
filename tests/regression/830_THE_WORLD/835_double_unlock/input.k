// The World in Koru — entry 4, the negative twin of 834_mutex_unlock.
// Doorway: Go's `mu.Unlock(); mu.Unlock()` — releasing a lock you've already
// released. In Go (and C) that's undefined behaviour: a runtime panic if you're
// lucky, silent corruption if you're not — `defer` does nothing to stop it.
//
// In Koru the released token's TYPE no longer carries `<held!>`, so a second
// `unlock` has no obligation to consume — the phantom checker rejects the reuse
// at compile time. Use-after-release is unrepresentable, not merely unlucky.
import std/io

pub event lock { name: []const u8 } -> []const u8<held!>
lock -> name

pub event unlock { name: []const u8<!held> }
unlock = std/io:print.ln("unlock {{ name:s }}")

// Release once (discharges <!held>), then try to release the same token again.
lock(name: "m"): m |> unlock(name: m) |> unlock(name: m)
