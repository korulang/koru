// A PROTO NAME REGISTERS ONCE. Two `std/types:proto(Engine)` declarations are
// a loud two-registrant collision — KORU030 naming BOTH declaration sites —
// not a silent merge into the second shape (phantom_semantic_checker.zig,
// registerDeclaredIdentity; ruled 2026-08-23). The wall fires in the
// backend's comptime phase, where the registry scan runs, so the refusal
// cites file:line for each registrant.
import std/types

std/types:proto(Engine) {
    rpm: i32
}

std/types:proto(Engine) {
    rpm: i32
    serial: string
}
