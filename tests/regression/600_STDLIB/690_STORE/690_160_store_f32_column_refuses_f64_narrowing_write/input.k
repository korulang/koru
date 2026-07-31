// PINS: the REFUSAL of a cross-width narrowing write — an f64-valued
// expression (f32 column + f64 column peer-resolves to f64) stored back
// into the f32 column. Narrowing loses bits; the write is refused, never
// silently rounded.
//
// The scalar gate admits both widths side by side (store.kz's i64/i32/
// f64/f32 set; f64 pinned at 690_021/690_111), and the WIDENING direction
// flows — f32 read into f64 arithmetic coerces losslessly. Only the
// narrowing store is refused, at the write envelope's typed slot.
//
// The pinned diagnostic is the backend's: it quotes emitted Zig, not the
// input.k write site. If a store-level wall lands in front of it, this
// substring stops matching and the pin flips — update it to the wall's
// diagnostic then.

import std/io
import std/store

std/store:new(bodies, capacity: 4) { x: f32, big: f64 }

std/store:insert(bodies) { x: 1.5, big: 2.25 }

std/store:sweep(bodies)
! sweep b |> std/store:stored { b.x: b.x + b.big }

std/store:sweep(bodies)
! sweep r |> std/io:print.ln("x {{ r.x:f }}")
