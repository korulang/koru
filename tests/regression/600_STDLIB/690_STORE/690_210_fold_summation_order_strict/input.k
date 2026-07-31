// PINS: the summation ORDER of an f64 fold through the sweep arm — strict
// program order, one row at a time, left to right. No pass may reassociate a
// float sum without a license the program granted; today no such license
// exists, so the order is the insertion order and nothing else.
//
// The column is a cancellation probe: [1e16, 1.0, -1e16, 1.0]. In strict
// order each 1.0 lands next to a running total of magnitude 1e16, where the
// f64 spacing is 2.0, and is absorbed; the 1e16s cancel; the last 1.0
// survives: checksum 1. ANY reassociated order — lane accumulators, pairwise
// trees, fast-math — keeps the 1.0s away from the big values and answers 2.
// There is no print-precision slack: the two orders differ by 1.0, not ulps.
//
// Measured 2026-07-31 (the fold probe): the strict order this test pins costs
// 5-8x against a reassociated sum at 10,000 rows — the reassociated fold
// vectorizes (fadd.2d x4), the strict one is a serial fadd chain. That cost
// is the price of this pin's guarantee, until a surface exists to waive it.
import std/io
import std/store

std/store:new(ents, capacity: 8) { x: f64 }
std/store:new(check) { sum: 0.0[f64] }
std/store:new(out) { v: 0.0[f64] }

std/store:watch(out)
! v x |> std/io:print.ln("checksum {{ x:f }}")

std/store:insert(ents) { x: 10000000000000000.0 }
std/store:insert(ents) { x: 1.0 }
std/store:insert(ents) { x: -10000000000000000.0 }
std/store:insert(ents) { x: 1.0 }

std/store:sweep(ents)
! sweep e |> std/store:stored { check.sum: check.sum + e.x }

std/store:stored { out.v: check.sum }
