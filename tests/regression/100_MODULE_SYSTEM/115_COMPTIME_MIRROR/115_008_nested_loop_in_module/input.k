// A nested `for` / `! each` loop inside a module tor, using NO synthesizing
// library — core loop machinery plus `io:print.ln`, which 115_001 pins as
// relocation-safe.
//
// The loop capture `__koru_item` is minted by the compiler's own each-machinery,
// not by any library, so this pins whether the uniquifying suffix that keeps
// nested captures distinct is applied to a flow declared in a module. 115_009
// holds the same body in the entry file as its control arm.
import app/lib

app/lib:run()
