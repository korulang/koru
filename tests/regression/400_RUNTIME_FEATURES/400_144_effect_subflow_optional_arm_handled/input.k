// OPTIONAL EFFECT ARMS from subflow impls, handled case — 400_130 with the
// arm declared OPTIONAL (`! ?pong`). Ruled 2026-07-03: firing an optional
// VOID arm is unconditional, exactly like a required arm; optionality is a
// consumer-side property (the consumer may omit the handler, 210_076).
// When the consumer DOES install the handler — this test — nothing about
// the fire changes: `pong(x)` is a plain arm-call, firing-is-a-call.
import std/io

pub event ping { x: i64 }
! ?pong i64

ping = pong(x)

ping(x: 41)
! pong reply |> std/io:print.ln("{{ reply + 1:d }}")
