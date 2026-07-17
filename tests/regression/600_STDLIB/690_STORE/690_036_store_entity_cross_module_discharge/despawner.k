// The despawn handler for Enemy, authored in a SEPARATE module. It consumes the
// module-qualified taken-obligation <std/store:!taken> and names the entity type
// via the cross-module type form `input:Enemy` (Enemy is synthesized in the main
// module — 220_001's module:Type syntax). Bare <!taken> would be rejected here
// per 330_088. Never called explicitly: auto-discharge is the sole caller.
import std/io

pub event discharge-enemy { enemy: input:Enemy<std/store:!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")
