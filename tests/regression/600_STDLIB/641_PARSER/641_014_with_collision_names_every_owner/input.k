// Pins that the KORU140 pick-wall names EVERY colliding vocabulary, not the
// first two it happens to find. 641_013 pins the two-owner case; this is the
// same wall with a third owner, which is where a fixed-arity outcome starts
// lying: it reports a pair, you qualify to escape it, and the one it never
// mentioned ambushes you as a fresh error on the next build.
//
// The guarded shape is the diagnostic's COMPLETENESS. A pick-wall exists to
// hand the author the whole set to choose from, so naming a subset defeats the
// wall's only purpose while still looking like it fired correctly.
import std/io
import app/alpha
import app/beta
import app/gamma

[with]app/alpha:ping(msg: "seed"): s |> [with]app/beta:ping(msg: s): t |> [with]app/gamma:ping(msg: t): u |> ping(msg: u): v |> std/io:print.ln("picked={{ v:s }}")
