// MIRROR of 220_017_effect_branch_multiline_chain: a `std/store:watch`
// subscription with a multi-line continuation chain, and the write that fires
// it, inside an imported module.
//
// A watch compiles INTO the write path rather than registering at runtime, so
// the subscription body and the write site have to resolve to one synthesized
// write-subflow. Both live in the module here, which is the case a library with
// private reactive state is made of.
import app/lib

app/lib:run()
