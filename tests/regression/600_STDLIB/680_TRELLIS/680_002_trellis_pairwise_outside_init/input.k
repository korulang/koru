// TEST: std/trellis — a VIOLATING program dies at the enforce, with a
// located koru-level diagnostic naming the trellis and the culprit.
//
// The stray `std/kernel:self` below sits at top level — its ancestry path is
// just `std/kernel:self`, which never matches the `std/kernel:init/kernel/.*`
// ok-arm and falls through to the error arm. The trellis check runs in
// Stage C BEFORE kernel transforms touch the tree, so the user gets the
// trellis message — not a transform panic or generated-Zig wreckage.
//
// Desired message shape (pinned as substring in expected_error.txt):
//
//   Check "kernel-shape" failed: std/kernel:self found outside std/kernel:init
//
// (Library prefixes `Check "<name>" failed: `; the message text is the
// error arm's payload, verbatim.)

import std/trellis
import std/kernel
import std/io

std/trellis:define("kernel-shape")
| `std/kernel:init/kernel/.*` _ => ok
| `.*std/kernel:pairwise` _ => error "std/kernel:pairwise found outside std/kernel:init"
| `.*std/kernel:self` _ => error "std/kernel:self found outside std/kernel:init"

std/trellis:enforce("kernel-shape")

std/kernel:shape(Body) {
    mass: f64,
}

// VIOLATION: self invoked outside any kernel:init scope.
std/kernel:self { k.mass *= 2.0 }
