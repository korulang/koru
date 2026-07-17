// The despawn handler for Enemy, authored in a SEPARATE module. It consumes the
// module-qualified taken-obligation <std/store:!taken> — the entity type Enemy is
// synthesized by the store in the main module; this module names its disposal
// contract across the boundary via the qualified state form (bare <!taken> would
// be rejected here per 330_088). Never called explicitly: auto-discharge is the
// sole caller, resolving this as the one <!taken> consumer.
import std/io

pub event discharge-enemy { enemy: Enemy<std/store:!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")
