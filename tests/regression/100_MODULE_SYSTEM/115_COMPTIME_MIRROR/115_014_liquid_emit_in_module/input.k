// MIRROR of 380_002_conditionals: `std/liquid_template:emit`, invoked bare as
// the keyword it is, relocated into an imported module.
//
// Bare keyword invocation is its own axis: resolution has to succeed from the
// name alone inside a module that never qualifies it, which is the same
// position 110_021 pins for `cond`. Here the callee is additionally a transform
// that renders at comptime.
import app/lib

app/lib:run()
