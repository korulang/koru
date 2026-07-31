// PINS: a column written by an EARLIER entry of a stored block feeding the
// rhs of SIXTEEN later entries in the same block — the determinant computed
// once into e.det, then every inverse entry dividing by the column instead of
// re-expanding it. This is the factoring 690_126's write order makes legal,
// and it is the spelling that turns heavy_compute's per-row cost from
// seventeen determinant expansions (690_127's naive form) into one.
//
// Same dense det-2 matrix as 690_127; the det column is printed back so the
// staged intermediate is itself pinned, not just its downstream quotients.
import std/io
import std/store

std/store:new(mats, capacity: 2) { t00: f64, t01: f64, t02: f64, t03: f64, t10: f64, t11: f64, t12: f64, t13: f64, t20: f64, t21: f64, t22: f64, t23: f64, t30: f64, t31: f64, t32: f64, t33: f64, o00: f64, o01: f64, o02: f64, o03: f64, o10: f64, o11: f64, o12: f64, o13: f64, o20: f64, o21: f64, o22: f64, o23: f64, o30: f64, o31: f64, o32: f64, o33: f64, det: f64 }

std/store:insert(mats) { t00: -3.0, t01: -3.0, t02: 2.0, t03: -3.0, t10: 2.0, t11: -3.0, t12: -1.0, t13: -3.0, t20: -1.0, t21: -1.0, t22: 2.0, t23: 2.0, t30: 1.0, t31: 2.0, t32: -3.0, t33: -3.0, o00: 0.0, o01: 0.0, o02: 0.0, o03: 0.0, o10: 0.0, o11: 0.0, o12: 0.0, o13: 0.0, o20: 0.0, o21: 0.0, o22: 0.0, o23: 0.0, o30: 0.0, o31: 0.0, o32: 0.0, o33: 0.0, det: 0.0 }

std/store:sweep(mats)
! sweep e |> std/store:stored {
        e.det: e.t00 * (e.t11 * e.t22 * e.t33 - e.t11 * e.t23 * e.t32 - e.t12 * e.t21 * e.t33 + e.t12 * e.t23 * e.t31 + e.t13 * e.t21 * e.t32 - e.t13 * e.t22 * e.t31) + e.t01 * (0.0 - e.t10 * e.t22 * e.t33 + e.t10 * e.t23 * e.t32 + e.t12 * e.t20 * e.t33 - e.t12 * e.t23 * e.t30 - e.t13 * e.t20 * e.t32 + e.t13 * e.t22 * e.t30) + e.t02 * (e.t10 * e.t21 * e.t33 - e.t10 * e.t23 * e.t31 - e.t11 * e.t20 * e.t33 + e.t11 * e.t23 * e.t30 + e.t13 * e.t20 * e.t31 - e.t13 * e.t21 * e.t30) + e.t03 * (0.0 - e.t10 * e.t21 * e.t32 + e.t10 * e.t22 * e.t31 + e.t11 * e.t20 * e.t32 - e.t11 * e.t22 * e.t30 - e.t12 * e.t20 * e.t31 + e.t12 * e.t21 * e.t30),
        e.o00: (e.t11 * e.t22 * e.t33 - e.t11 * e.t23 * e.t32 - e.t12 * e.t21 * e.t33 + e.t12 * e.t23 * e.t31 + e.t13 * e.t21 * e.t32 - e.t13 * e.t22 * e.t31) / e.det,
        e.o01: (0.0 - e.t01 * e.t22 * e.t33 + e.t01 * e.t23 * e.t32 + e.t02 * e.t21 * e.t33 - e.t02 * e.t23 * e.t31 - e.t03 * e.t21 * e.t32 + e.t03 * e.t22 * e.t31) / e.det,
        e.o02: (e.t01 * e.t12 * e.t33 - e.t01 * e.t13 * e.t32 - e.t02 * e.t11 * e.t33 + e.t02 * e.t13 * e.t31 + e.t03 * e.t11 * e.t32 - e.t03 * e.t12 * e.t31) / e.det,
        e.o03: (0.0 - e.t01 * e.t12 * e.t23 + e.t01 * e.t13 * e.t22 + e.t02 * e.t11 * e.t23 - e.t02 * e.t13 * e.t21 - e.t03 * e.t11 * e.t22 + e.t03 * e.t12 * e.t21) / e.det,
        e.o10: (0.0 - e.t10 * e.t22 * e.t33 + e.t10 * e.t23 * e.t32 + e.t12 * e.t20 * e.t33 - e.t12 * e.t23 * e.t30 - e.t13 * e.t20 * e.t32 + e.t13 * e.t22 * e.t30) / e.det,
        e.o11: (e.t00 * e.t22 * e.t33 - e.t00 * e.t23 * e.t32 - e.t02 * e.t20 * e.t33 + e.t02 * e.t23 * e.t30 + e.t03 * e.t20 * e.t32 - e.t03 * e.t22 * e.t30) / e.det,
        e.o12: (0.0 - e.t00 * e.t12 * e.t33 + e.t00 * e.t13 * e.t32 + e.t02 * e.t10 * e.t33 - e.t02 * e.t13 * e.t30 - e.t03 * e.t10 * e.t32 + e.t03 * e.t12 * e.t30) / e.det,
        e.o13: (e.t00 * e.t12 * e.t23 - e.t00 * e.t13 * e.t22 - e.t02 * e.t10 * e.t23 + e.t02 * e.t13 * e.t20 + e.t03 * e.t10 * e.t22 - e.t03 * e.t12 * e.t20) / e.det,
        e.o20: (e.t10 * e.t21 * e.t33 - e.t10 * e.t23 * e.t31 - e.t11 * e.t20 * e.t33 + e.t11 * e.t23 * e.t30 + e.t13 * e.t20 * e.t31 - e.t13 * e.t21 * e.t30) / e.det,
        e.o21: (0.0 - e.t00 * e.t21 * e.t33 + e.t00 * e.t23 * e.t31 + e.t01 * e.t20 * e.t33 - e.t01 * e.t23 * e.t30 - e.t03 * e.t20 * e.t31 + e.t03 * e.t21 * e.t30) / e.det,
        e.o22: (e.t00 * e.t11 * e.t33 - e.t00 * e.t13 * e.t31 - e.t01 * e.t10 * e.t33 + e.t01 * e.t13 * e.t30 + e.t03 * e.t10 * e.t31 - e.t03 * e.t11 * e.t30) / e.det,
        e.o23: (0.0 - e.t00 * e.t11 * e.t23 + e.t00 * e.t13 * e.t21 + e.t01 * e.t10 * e.t23 - e.t01 * e.t13 * e.t20 - e.t03 * e.t10 * e.t21 + e.t03 * e.t11 * e.t20) / e.det,
        e.o30: (0.0 - e.t10 * e.t21 * e.t32 + e.t10 * e.t22 * e.t31 + e.t11 * e.t20 * e.t32 - e.t11 * e.t22 * e.t30 - e.t12 * e.t20 * e.t31 + e.t12 * e.t21 * e.t30) / e.det,
        e.o31: (e.t00 * e.t21 * e.t32 - e.t00 * e.t22 * e.t31 - e.t01 * e.t20 * e.t32 + e.t01 * e.t22 * e.t30 + e.t02 * e.t20 * e.t31 - e.t02 * e.t21 * e.t30) / e.det,
        e.o32: (0.0 - e.t00 * e.t11 * e.t32 + e.t00 * e.t12 * e.t31 + e.t01 * e.t10 * e.t32 - e.t01 * e.t12 * e.t30 - e.t02 * e.t10 * e.t31 + e.t02 * e.t11 * e.t30) / e.det,
        e.o33: (e.t00 * e.t11 * e.t22 - e.t00 * e.t12 * e.t21 - e.t01 * e.t10 * e.t22 + e.t01 * e.t12 * e.t20 + e.t02 * e.t10 * e.t21 - e.t02 * e.t11 * e.t20) / e.det
}

std/store:sweep(mats)
! sweep r |> std/io:print.ln("r0 {{ r.o00:f }} {{ r.o01:f }} {{ r.o02:f }} {{ r.o03:f }}") |> std/io:print.ln("r1 {{ r.o10:f }} {{ r.o11:f }} {{ r.o12:f }} {{ r.o13:f }}") |> std/io:print.ln("r2 {{ r.o20:f }} {{ r.o21:f }} {{ r.o22:f }} {{ r.o23:f }}") |> std/io:print.ln("r3 {{ r.o30:f }} {{ r.o31:f }} {{ r.o32:f }} {{ r.o33:f }}") |> std/io:print.ln("det {{ r.det:f }}")
