// PINS: `stripe(s) |> tail` JOINS the chain — the tail runs after the sweep,
// on the same contract 690_028 pins for `stored`. The stripe verb rewrite
// carries the flow's continuations into the replacement; a stripe is a
// chain step, not a chain terminator. Every earlier stripe in the corpus
// (690_014/045/200/201) is chain-terminal, so only this test can see a
// swallowed tail: "stage, sweep, then continue" is one chain.

import std/io
import std/store

std/store:new(game, capacity: 4) { hp: i64 }

std/store:insert(game) { hp: 3 }

std/store:rule(game)
! row e |> std/io:print.ln("hp {{ e.hp:d }}")

std/store:stripe(game) |> std/io:print.ln("tail survived")
