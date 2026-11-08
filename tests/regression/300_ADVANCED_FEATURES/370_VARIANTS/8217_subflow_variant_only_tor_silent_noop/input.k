// Test 8217: a subflow-variant-ONLY tor called with no selection.
//
// `greet` declares two variant arms and NO default (`~greet = ...`)
// arm. Nothing registers a variant, so the unqualified `greet()` call
// has no implementation to dispatch to. The proc-variant twin of this
// shape (proc-only variants, no |zig, no registry hit) emits a named
// runtime panic — "reached 'X', which nothing implements — this program
// was built with the box still empty". The subflow-variant path instead
// emits `__koru_handler_impl { return undefined; }`: the call is a
// SILENT NO-OP and the program runs to completion looking healthy.
//
// Desired: the same loud failure the proc path gives — a compile
// refusal or the runtime panic, whichever the variant-emission fix
// lands. This pin asserts refusal; if the fix is runtime-panic parity
// instead, retarget EXPECT/the markers then (TODO says so).

import std/io
import std/build

pub tor greet {}

greet|en = std/io:print("hello")

greet|no = std/io:print("hei")

// No std/build:variants registration — deliberately unselected.

greet()
std/io:print("after")
