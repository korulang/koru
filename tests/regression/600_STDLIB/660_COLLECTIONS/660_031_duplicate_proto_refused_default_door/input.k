// The duplicate wall through the DEFAULT DOOR. Two std/proto(Engine)
// declarations must collide loudly — KORU030 naming BOTH declaration sites —
// exactly as two std/types:proto(Engine) do in 660_029. The wall fires in
// phantom_semantic_checker.zig registerDeclaredIdentity; the 2026-09-03
// proto_door rung widened the scan so `std/proto:default(Engine)` registers
// the entry AND its derived container (`List_Engine`) — a second registrant
// is a loud collision, never a silent merge.
import std/proto

std/proto(Engine) {
    rpm: i32
}

std/proto(Engine) {
    rpm: i32
    serial: string
}