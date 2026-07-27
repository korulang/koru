// PINS: a subflow body runs EVERY step of its chain, whatever its first step
// lowers to.
//
// `std/io:print.ln` is a comptime transform: the compiler renders it in place
// instead of calling a handler. So a chain headed by one is emitted by a
// different route than a chain headed by an ordinary call — and the steps
// AFTER the head are what that route has to carry.
//
// The controls, all three of which take the other route:
//
//     say-a() |> print.ln("b") |> print.ln("c")          <- head is a call
//     app/lib:emit-a() |> app/lib:emit-b()               <- head is cross-module
//     print.ln("a") |> print.ln("b")  at TOP LEVEL       <- not a subflow body
//
// Same steps, same order, same file form. Only what the head lowers to, and
// whether the chain is a subflow body, moves — so a chain that shortens here
// while the controls stay whole names the route, not the steps.
//
// The failure this guards is silent: the program compiles, runs, exits 0, and
// prints less than it was written to print. Nothing in a green suite
// distinguishes a pipeline that ran from one that stopped after its head,
// which is why the shape is pinned rather than left to review.
//
// Sibling of 210_172 (a step's result must move forward) and 210_174 (a line
// break must not change what a chain means): all three say a pipeline means
// the pipeline that was written. 210_169 makes the same claim through a
// `print.blk` head with a multi-line source block, and 220_021 makes it by
// COUNT for a chain of void handler calls.
import std/io

tor run {}

run = std/io:print.ln("a") |> std/io:print.ln("b") |> std/io:print.ln("c")

run()
