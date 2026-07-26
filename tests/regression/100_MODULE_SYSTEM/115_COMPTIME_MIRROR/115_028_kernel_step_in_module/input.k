// MIRROR of 390_070_step_basic: `std/kernel:step` wrapping a `kernel:self` in
// the continuation chain, inside an imported module.
//
// step is the kernel-native iteration form — it wraps the ops that follow it
// rather than expanding at its own site, so it pins whether a transform that
// claims its DESCENDANTS still finds them when the whole chain is a module tor
// body.
import app/lib

app/lib:run()
