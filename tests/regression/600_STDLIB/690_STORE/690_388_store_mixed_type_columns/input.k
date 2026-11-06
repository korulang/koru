// ASPIRATION — pin (gallery transition spike, 2026-11-06): a SINGLETON
// store mixing i64 and f64 columns refuses — "mixed column types in one
// store are a later slice". 690_021 pins homogeneous f64 singletons and
// 690_049 pins CONTAINER mixed columns; the singleton mixed case is the
// gap the gallery hit putting tween state (f64) beside counters (i64).
import std/io
import std/store

std/store:new(m) { i: 0[i64], f: 0.0[f64] }

std/store:watch(m)
! i v |> std/io:print.ln("i {{ v:d }}")

std/store:watch(m)
! f v |> std/io:print.ln("f {{ v:f }}")

std/store:stored { m.i: 5, m.f: 2.5 }
